module Frontend.Desugar (desugar) where

import           Javalette.Abs
import           Javalette.ErrM

import           Internal.Types

import qualified Control.Monad.Reader as CMR (ReaderT, asks, runReaderT)
import qualified Control.Monad.State  as CMS (StateT, evalStateT, gets, modify)

import           Control.Monad        (foldM, liftM, liftM2, liftM3)

import           Data.Map             (Map)
import qualified Data.Map             as M (empty, insert, lookup, map,
                                            mapWithKey, toList, union)

import qualified Data.List            as L (delete, union, unionBy)

data ReadEnv   = REnv { pointers  :: Pointers
                      , classes   :: Classes }

data StateEnv  = SEnv { sugarVar  :: Int
                      , classAttr :: [Ident] }
               
type Pointers = Map Ident Ident

type Desugar a = CMR.ReaderT ReadEnv (CMS.StateT StateEnv Err) a


newClassAttr :: [Ident] -> Desugar ()
newClassAttr attr = CMS.modify (\env -> env { classAttr = attr })

emptyClassAttr :: Desugar ()
emptyClassAttr = CMS.modify (\env -> env { classAttr = [] })

deleteClassAttr :: Ident -> Desugar ()
deleteClassAttr id =
  CMS.modify (\env -> env { classAttr = L.delete id $ classAttr env })

isClassAttr :: Ident -> Desugar Bool
isClassAttr id = CMS.gets ((elem id) . classAttr)

-- | Take a new unique variable to use in desugar.
newSugarVar :: Desugar Ident
newSugarVar = do
  var <- CMS.gets sugarVar
  CMS.modify (\env -> env { sugarVar = sugarVar env + 1})
  return . Ident $ "_" ++ show var

-- | Split top level defintions in structs, pointers, classes and functions.
splitDefinitions :: [TopDef] -> ([TypeDecl],[TypeDecl],[TypeDecl],[FnDef])
splitDefinitions defs =
  (\(a,b,c,d) -> (reverse a,reverse b, reverse c, reverse d))
  $ foldl select ([], [], [], []) defs
  where
    select (s, p, c, f) definition =
      case definition of
        TopFnDef def@(FunDef _ _ _ _)      -> (s, p, c, def:f)
        TopTypeDecl def@(StructDef _ _)    -> (def:s, p, c, f)
        TopTypeDecl def@(PtrDef _ _)       -> (s, def:p, c, f)
        TopTypeDecl def@(ClassDef _ _ _ _) -> (s, p, def:c, f)

-- | Desugar a program without typechecking.
desugar:: Program -> Err (Structs, Classes, [FnDef])
desugar (Prog defs) = do
  let (s, p, c, f)   = splitDefinitions defs
  (structs,pointers)  <- checkStructs p s
  (classes,methods )  <- checkClasses c
                         
  let initialREnv     = REnv pointers classes
      initialSEnv     = SEnv 0 []

      -- Top level functions have no class attributes. 
      functionsTL     = zip (repeat Nothing) f
      methodsTL       = methods
                                     
  desugaredTopLevel  <- CMS.evalStateT
                        (CMR.runReaderT (mapM
                                         (uncurry desugarFnDef)
                                         (functionsTL ++ methodsTL))
                         initialREnv)
                        initialSEnv
  return (structs, classes, desugaredTopLevel)

-- | Check top level struct declaration against pointer declaration,
--   checking for name clashes. Also check that Classes do not clash
--   with Structures.
checkStructs :: [TypeDecl] -- ^ Pointer definitions
             -> [TypeDecl] -- ^ Struct  definitions
             -> Err (Structs, Pointers)

checkStructs pointerDefs structDefs  = do
  pointers <- foldM
              (\m (PtrDef (Ref strName) ptr@(Ident synom)) ->
                 if synom `elem` ["int", "double", "bool", "void"] then
                   fail $ "Pointer has the same name as a primitive type."
                 else
                   case M.lookup ptr m of
                     Nothing ->
                       if any (\(StructDef name _) -> name == strName) structDefs
                       then
                         return $ M.insert ptr strName m
                       else
                         fail $ concat [ "Pointer "
                                       , synom
                                       , " not refering to a struct."]
                     Just _  -> fail $ concat [ "Pointer "
                                              , synom
                                              , " already defined."]
              ) M.empty pointerDefs

  structs <- foldM
             (\m (StructDef name fields) ->
                case M.lookup name m of
                  Just _  -> fail $ concat ["Struct "
                                           , show name
                                           , "already defined."]
                  Nothing -> do
                    checkedFields <-
                      foldM
                      (\f (StrField t id) ->
                         case t of
                           Ref name ->
                             case M.lookup name pointers of
                               Nothing ->
                                 fail $ concat [ "Field "
                                               , show id
                                               , " is not a valid pointer"]
                               Just strName ->
                                 return $ f ++ [StrField (Pointer strName) id]
                           _ ->  return  $ f ++ [StrField t id]
                      ) [] fields
                    return $ M.insert name checkedFields m
             ) M.empty structDefs

  return (structs, pointers)

-- | Check all class defined by user returning a suitable representation.
--   Not yet implemented to check clashes with structures!!!
checkClasses :: [TypeDecl] -- ^ Class  definitions
             -> Err (Classes, [(Maybe [Ident], FnDef)])
checkClasses classDef = 
  do classesInfo <- findClassesInfo
     foldM
      (\(classes,methods)
        (ClassDef className@(Ident class') hierarchy attr classMethods) ->
         case M.lookup className classes of
           Just _  -> fail $ concat ["Class name "
                                    , show className
                                    , " already defined."]
           Nothing ->
             do (superT, parentAttr, parentMethods) <-
                  case hierarchy of
                    HEmpty -> return ([],[],[])
                    HExtend parent ->
                      case M.lookup parent classes of
                        Nothing -> fail $ concat [ "Class "
                                                 , show className
                                                 , "extending a class not defined."]
                        Just (superT,attr,methds) ->
                          return (parent : superT, attr, methds)

                attr <-
                  foldM
                  (\fields (StrField t id) ->
                     case t of
                       Ref name ->
                         if name == className then
                           return (fields ++ [StrField (Object name superT) id])
                         else
                           case M.lookup name classesInfo of
                             Nothing      -> fail $ concat [ "Class "
                                                 , show name
                                                 , " not defined."]
                             Just superT ->
                               return $ fields ++ [StrField (Object name superT) id]
                       _ ->  return  $ fields ++ [StrField t id]
                  ) [] attr

                let desugaredMethods =
                      map (\(FunDef type' (Ident id) args block) ->
                             (Just $ map (\(StrField t id) -> id) attr

                             ,MethodDef type'
                                        (Ident $ class'  ++ "." ++ id)
                                        (Argument (Object className superT) (Ident "self"))
                                        args
                                        block)) classMethods
                                                  
                return (M.insert className ( superT
                                      , L.union parentAttr attr  
                                      , classMethods)
                        classes
                       , methods ++ desugaredMethods)
      ) (M.empty, []) classDef 
  where
    findClassesInfo :: Err (Map Ident [Ident])
    findClassesInfo = foldM (\m (ClassDef className hierarchy _ _) -> 
                        do superT <- case hierarchy of
                                          HEmpty -> return []
                                          HExtend parent -> 
                                            case M.lookup parent m of
                                              Nothing -> fail $ concat [ "Class "
                                                                       , show className
                                                                       , "extending a class not defined."]
                                              Just superT -> return $  parent:superT
                           return $ M.insert className superT m) M.empty classDef 

-- | Desugar a function definition.
desugarFnDef :: Maybe [Ident] -> FnDef -> Desugar FnDef
desugarFnDef Nothing (FunDef type' id args block) =
  do desugaredType  <- desugarType type'
     desugaredArgs  <- mapM desugarArg args
     desugaredBlock <- desugarBlock block
     return (FunDef desugaredType id desugaredArgs desugaredBlock)

desugarFnDef (Just classAttr) (MethodDef type' id obj args block) =
  do
    newClassAttr classAttr
    desugaredType  <- desugarType type'
    desugaredArgs  <- mapM desugarArg args
    desugaredBlock <- desugarBlock block
    emptyClassAttr
    return (MethodDef desugaredType id obj desugaredArgs desugaredBlock)

  
-- | Desgugar an Argument.
desugarArg :: Arg -> Desugar Arg
desugarArg (Argument type' id) = do
  desugaredType <- desugarType type'
  deleteClassAttr id
  return (Argument desugaredType id)

-- | Desugar a block.
desugarBlock :: Block -> Desugar Block
desugarBlock (SBlock stmts) = fmap SBlock $ mapM desugarStmt stmts

-- | Desugar a statement.
desugarStmt :: Stmt -> Desugar Stmt
desugarStmt stmt = case stmt of
  BStmt block  -> fmap BStmt $ desugarBlock block
  Decl type' items     -> do
    desugaredType  <- desugarType type'
    desugaredItems <- mapM desugarItem items
    return (Decl desugaredType desugaredItems)
  For (ForDecl t id) exp@(Var v eDims) innerStm ->
    do index  <- newSugarVar
       len    <- newSugarVar
       desugaredType <- desugarType t
       desugaredStmt <- desugarStmt innerStm
       return $ (BStmt
                 (SBlock
                  [ Decl Int [Init index  (ELitInt 0)]
                  , Decl Int [Init len (Method exp (Var (Ident "length") [])) ]
                  , Decl desugaredType [NoInit id]
                  , While (ERel
                           (Var index [])
                           LTH
                           (Var len []))
                            (BStmt
                             (SBlock
                              [Ass (LValVar id [])
                                     (Var v (eDims
                                             ++ [DimAddr (Var index [])]))
                              , Incr (LValVar index [])
                              , desugaredStmt
                              ]))
                  ]))
  For _ _ _ -> fail "The expression should be a variable."
  Ass lval expr   -> liftM2 Ass (desugarLVal lval) (desugarExpr expr)
  Ret expr        -> liftM Ret $ desugarExpr expr
  Cond expr stmt  -> liftM2 Cond (desugarExpr expr) (desugarStmt stmt)
  CondElse expr stmt1 stmt2  ->
    liftM3 CondElse (desugarExpr expr) (desugarStmt stmt1) (desugarStmt stmt2)
  While expr stmt -> liftM2 While (desugarExpr expr) (desugarStmt stmt)
  SExp expr       -> liftM SExp $ desugarExpr expr
  Incr lval       -> liftM Incr $ desugarLVal lval
  Decr lval       -> liftM Decr $ desugarLVal lval
  _               -> return stmt

-- | Desugar a LVal
desugarLVal :: LVal -> Desugar LVal
desugarLVal lval = case lval of
  LValVar id dimas  -> do
    isAttr <- isClassAttr id
    if isAttr then
      return (LValStr (Ident "self") id)
    else
      liftM (LValVar id) (mapM desugarDimA dimas)
  LValStr id1 id2   -> return (LValStr id1 id2)

-- | Desugar a Item.
desugarItem :: Item -> Desugar Item
desugarItem item = case item of
  Init id expr -> do
    desugaredExpr <- desugarExpr expr
    deleteClassAttr id
    return (Init id desugaredExpr)
  NoInit id -> do
    deleteClassAttr id
    return (NoInit id)

-- | Desugar a Type.
--   If the type is a Name (Structures, Classes) then
--   the type is desugared into the name of the structure
--   is pointing to, adding subtype information to it.
desugarType :: Type -> Desugar Type
desugarType ty =
  case ty of
    Array t' dims -> return $ DimT t' (fromIntegral $ length dims)
    Ref name ->
      do pointers <- CMR.asks pointers
         classes  <- CMR.asks classes
         case M.lookup name pointers of
           Just strName  -> return (Pointer strName)
           Nothing       ->
             case M.lookup name classes of
               Just (superTypes, _, _) -> return (Object name superTypes)
               Nothing                 -> return (Pointer name)
    _            -> return ty

-- | Desugar a DimA.
desugarDimA :: DimA -> Desugar DimA
desugarDimA (DimAddr expr) = liftM DimAddr $ desugarExpr expr

-- | Desugar an expresion.
desugarExpr :: Expr -> Desugar Expr
desugarExpr expr =
  case expr of
    Var id dimas -> do
      isAttr <- isClassAttr id
      if isAttr then
        return (PtrDeRef (Ident "self") id)
      else
        liftM (Var id) (mapM desugarDimA dimas)
    ENew type' dimas  -> liftM2 ENew (desugarType type') (mapM desugarDimA dimas)
    ENull id ->
      do t <- desugarType (Ref id)
         case t of
           Pointer name   -> return (ENull name)
           Object  name _ -> return (ENull name)

    EApp id@(Ident name) exprs  ->
      liftM (EApp id) $ mapM desugarExpr exprs

    ERel expr1 relop expr2  -> do
      desugaredExpr1 <- desugarExpr expr1
      desugaredExpr2 <- desugarExpr expr2
      return (ERel desugaredExpr1 relop desugaredExpr2)
    Method expr1 (EApp id exprs) ->
      do object <- desugarExpr expr1
         args   <- mapM desugarExpr exprs
         return $  MApp id object args
    Neg expr  -> liftM Neg $ desugarExpr expr
    Not expr  -> liftM Not $ desugarExpr expr
    EMul expr1 mulop expr2  -> do
      desugaredExpr1 <- desugarExpr expr1
      desugaredExpr2 <- desugarExpr expr2
      return (EMul desugaredExpr1 mulop desugaredExpr2)
    EAdd expr1 addop expr2  -> do
      desugaredExpr1 <- desugarExpr expr1
      desugaredExpr2 <- desugarExpr expr2
      return (EAdd desugaredExpr1 addop desugaredExpr2)
    EAnd expr1 expr2  -> liftM2 EAnd (desugarExpr expr1) (desugarExpr expr2)
    EOr  expr1 expr2  -> liftM2 EOr  (desugarExpr expr1) (desugarExpr expr2)
    _ -> return expr
