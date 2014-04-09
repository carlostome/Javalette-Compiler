{-# LANGUAGE GeneralizedNewtypeDeriving, RankNTypes #-}
-- | Implements a type checker for the Javalette language.
module Frontend.TypeChecker where
import Debug.Trace

import Javalette.ErrM
import Javalette.Abs

import Data.Foldable (foldlM)
import Data.Map (Map)
import qualified Data.Map as Map

import Control.Monad (zipWithM_, forM, unless)
import Control.Monad.State as CMS

-- | An environment is a pair containing information about functions 
-- and variables defined. It supports different scopes.
data Env = Env { functions :: Functions
               , context   :: [Context]
               , sugarVar  :: Int }

-- | The functions information is a relation name ->  
-- list of types (arguments) and the return type.
type Functions = Map Ident ([Type], Type) 

-- | A context is a relation identifier -> (type, number of dimensions) 
-- (variables).
type Context = Map Ident Type 

-- | This monad holds a state and allows to stop the execution 
-- returning an error.
newtype TypeCheck a = TypeCheck { runType :: StateT Env Err a }
    deriving (Monad,MonadState Env)
             
-- | Looks for a variable in the environment.
lookupVar :: Ident -> TypeCheck Type
lookupVar id = do
  cntx <- CMS.gets context
  look cntx
    where
      look [] = fail $ "Variable " ++ show id ++ " not declared."
      look (top:rest) = case Map.lookup id top of
                           Nothing -> look rest
                           Just t  -> return t

-- | Looks for a function in the environment.
lookupFun :: Ident -> TypeCheck ([Type],Type)
lookupFun id = do
  functions <- CMS.gets functions
  case Map.lookup id functions of
    Nothing -> fail $ "Function " ++ show id ++ " not declared."
    Just t  -> return t

-- | Adds a variable type to the context if it does not exists.
createVarIfNotExists :: Ident -> Type -> TypeCheck ()
createVarIfNotExists id t = do
  top:rest <- CMS.gets context
  case Map.lookup id top of
    Nothing   -> CMS.modify (\env -> env { context = Map.insert id t' top : rest })
    Just _    -> fail $ concat [ "Variable "
                              , show id 
                              , " already defined." ]
  where
    t' = case t of
      Array t dims -> DimT t (fromIntegral $ length dims)
      _            -> t
  
                              
-- | Deletes a variable.
deleteVar :: Ident -> TypeCheck ()
deleteVar id = do
  top:rest <- CMS.gets context
  CMS.modify (\env -> env { context =  Map.delete id top: rest })

-- | Updates the function signature in the environment
-- unless it was previously defined (in that case throws an error).
createFunIfNotExists :: Ident -> ([Type],Type) -> TypeCheck ()
createFunIfNotExists id (argTypes, retType) = do
  fun <- CMS.gets (Map.lookup id . functions) 
  case fun of
    Just  _ -> fail $ "Function " ++ show id ++ " defined twice."
    Nothing -> CMS.modify
               (\env -> env { functions = Map.insert id
                                          types' (functions env)})
      where
        types'  = (map toDim argTypes, toDim retType)
        toDim t = case t of
                     Array t' dims -> DimT t' (fromIntegral $ length dims)
                     _            -> t
  

-- | Creates a new context for variables.
newBlock :: TypeCheck ()
newBlock = CMS.modify (\env -> env {context =  Map.empty : context env})

-- | Removes a context of variables.
removeBlock :: TypeCheck ()
removeBlock  = CMS.modify (\env -> env { context = tail $ context env})

-- | Creates an empty environment.
emptyEnv :: Env
emptyEnv = Env { functions   = Map.empty
               , context     = []
               , sugarVar    = 0 }

newSugarVar :: TypeCheck Ident
newSugarVar = do
  var <- CMS.gets sugarVar
  CMS.modify (\env -> env {sugarVar = sugarVar env + 1})
  return (Ident $ '_' : show var)
               
-- | Initializes the environment, adding all the primitive functions.
initializeEnv :: Program -> TypeCheck ()
initializeEnv (Prog defs) = mapM_ addFun (initializeDefs ++ defs)
  where
    addFun (FnDef t id args _) = createFunIfNotExists id (map (\(Argument t _) -> t) args, t)
    initializeDefs = [ FnDef Void (Ident "printInt")    [Argument Int (Ident "x")]  (SBlock [])
                     -- void   printInt(int x) 
                     , FnDef Void (Ident "printDouble") [Argument Doub (Ident "x")] (SBlock [])
                     -- void  printDouble(double x)
                     , FnDef Void (Ident "printString") [Argument String (Ident "x")] (SBlock [])
                     -- void printString(String x)
                     , FnDef Int  (Ident "readInt")     []                     (SBlock [])
                     -- int readInt()             
                     , FnDef Doub (Ident "readDouble")  []                     (SBlock [])
                     -- double readDouble()
                     ]

-- | Returns the length of a list as an Integer 
-- (instead of Int).
length' :: [a] -> Integer
length' = fromIntegral . length

-- | Typechecks a program.
typecheck :: Program -> Err Program
typecheck program = evalStateT (runType $ typeCheckProgram program) emptyEnv
  where
    typeCheckProgram :: Program -> TypeCheck Program
    typeCheckProgram (Prog defs) = do
    initializeEnv program
    typedDefs <- mapM typeCheckDef defs
    return (Prog typedDefs)

-- | Typechecks a function definition.
typeCheckDef :: TopDef -> TypeCheck TopDef 
typeCheckDef (FnDef ret_t id args (SBlock stmts)) = do
  newBlock
  mapM_ (\(Argument t idArg)  -> createVarIfNotExists idArg t) args
  (has_ret, BStmt typedStmts) <- typeCheckStmt ret_t' (BStmt (SBlock stmts))
  unless (has_ret || typeEq ret_t Void) $ fail $ "Missing return statement in function " ++ show id
  removeBlock
  return $ FnDef ret_t' id args typedStmts
    where
      ret_t' = case ret_t of
                 Array t' dims -> DimT t' (fromIntegral $ length dims)
                 _             -> ret_t
-- Casts a dimension addressing to an expression.
dimToExpr :: DimA -> Expr
dimToExpr (DimAddr e) = e

-- Casts a dimension addressing list to an 
-- expression list.
dimsToExprs :: [DimA] -> [Expr]
dimsToExprs = map dimToExpr

-- | Casts an expressions list to a list of 
-- dimension addressings.
exprsToDims :: [Expr] -> [DimA]
exprsToDims = map DimAddr

-- | Typechecks the validity of a given statement.
typeCheckStmt :: Type -> Stmt -> TypeCheck (Bool, Stmt)
typeCheckStmt funType stm = 
    case stm of
      Empty -> return (False, Empty)
      BStmt (SBlock stmts) -> do
               newBlock
               results <- mapM (typeCheckStmt funType) stmts
               let (rets, typedStmts) = unzip results
               removeBlock
               return (or rets, BStmt (SBlock typedStmts))
      Decl t items -> do
               typedExprs <- mapM (checkItem t') items
               let typedItems = zipWith typeItem items typedExprs
               mapM_ (uncurry createVarIfNotExists) $ zip (map getIdent items) (repeat t') 
               return (False, Decl t' typedItems) 
          where
            t' = case t of
                   Array t' ndims -> DimT t' (fromIntegral $ length ndims)
                   _             -> t
            checkItem t (NoInit id)   = return Nothing
            checkItem t (Init id exp) = do
                        typedExpr <- checkTypeExpr t exp 
                        return $ Just typedExpr
            typeItem (NoInit id) Nothing = NoInit id
            typeItem (Init id _) (Just typedExpr) = Init id typedExpr
            getIdent (NoInit id)    = id
            getIdent (Init id _)    = id
                                      
      Ass ident ndims exp -> do
        typedAddrExpr   <- mapM (checkTypeExpr Int) $ dimsToExprs ndims
        t               <- lookupVar ident
        let dimT = case t of
                     DimT t' tDim -> DimT t' (tDim - fromIntegral (length ndims))
                     t'           -> t'
        typedExpr       <- checkTypeExpr dimT exp
        return (False, Ass ident (exprsToDims typedAddrExpr) typedExpr)

      Incr ident -> 
          lookupVar ident >>= checkTypeNum  >>= (\typedExpr -> return (False, stm))
      Decr ident -> 
          lookupVar ident >>= checkTypeNum  >>= (\typedExpr -> return (False, stm))
      Ret exp ->
          checkTypeExpr funType exp >>= (\typedExpr -> return (True, Ret typedExpr))
      VRet    -> if typeEq funType Void then return (True, VRet)
                 else fail "Not valid return type"
      Cond exp stm1 -> do
               typedExpr <- checkTypeExpr Bool exp
               newBlock
               (has_ret, typedStmt) <- typeCheckStmt funType stm1
               removeBlock
               case exp of
                 ELitTrue -> return (has_ret, Cond typedExpr typedStmt)
                 _        -> return (False, Cond typedExpr typedStmt) 
      CondElse exp stm1 stm2 -> do
               typedExpr <- checkTypeExpr Bool exp
               newBlock
               (ret1, typedStmt1) <- typeCheckStmt funType stm1
               -- Cleans the current block.
               removeBlock
               newBlock
               (ret2, typedStmt2) <- typeCheckStmt funType stm2
               removeBlock
               let has_ret = case exp of
                              ELitTrue  -> ret1
                              ELitFalse -> ret2
                              _         -> ret1 && ret2
               return (has_ret, CondElse typedExpr typedStmt1 typedStmt2)
      While exp stm' -> do
               typedExpr <- checkTypeExpr Bool exp
               (stm_has_ret, typedStmt) <- typeCheckStmt funType stm'
               let has_ret = case exp of
                          ELitTrue  -> stm_has_ret
                          _         -> False
               return (has_ret, While typedExpr typedStmt)
      SExp exp -> inferTypeExpr exp >>= 
                  (\typedExpr -> return (False, SExp typedExpr))
      For (ForDecl t id) exp@(Var v eDims) innerStm -> do
               (ETyped _ type'@(DimT t' nDims)) <- inferTypeExpr exp
               index  <- newSugarVar
               len    <- newSugarVar
               typeCheckStmt funType
                   (BStmt
                    (SBlock
                     [ Decl Int [Init index  (ELitInt 0)]
                     , Decl Int [Init len (EArrL v eDims)]
                     , Decl (DimT t' (nDims -1)) [NoInit id]
                     , While (ERel
                              (Var index [])
                              LTH
                              (Var len []))
                               (BStmt
                                (SBlock
                                 [Ass id [] (Var v (eDims ++ [DimAddr (Var index [])]))
                                 , Incr index
                                 , innerStm
                                 ]))
                     ]))
      For (ForDecl t id) _ innerStm -> fail "The expression should be a variable."


                            
-- | Calculate type equality with dimensional check.
typeEq :: Type -> Type -> Bool
typeEq (DimT t1 dim1) (DimT t2 dim2) =  t1 == t2 && dim1 == dim2
typeEq (DimT t1 dim1) t2             =  t1 == t2 && dim1 == 0
typeEq t1             (DimT t2 dim2) =  t1 == t2 && dim2 == 0
typeEq t1             t2             =  t1 == t2
                                       
-- | Checks the type of an expresion in the given environment.
checkTypeExpr :: Type -> Expr -> TypeCheck Expr
checkTypeExpr t exp = do
  typedExpr@(ETyped _ expt') <- inferTypeExpr exp
  when (not $ typeEq t expt') $
       fail $ concat ["Expresion "
                     , show exp
                     , " has not type "
                     , show t
                     , ", instead has "
                     , show expt', "."]
  return typedExpr

-- | Infers the type of a expression in the given environment.
inferTypeExpr :: Expr -> TypeCheck Expr
inferTypeExpr exp = 
  case exp of
      ELitTrue         -> return $ ETyped exp Bool
      ELitFalse        -> return $ ETyped exp Bool
      ELitInt n        -> return $ ETyped exp Int
      ELitDoub d       -> return $ ETyped exp Doub
      Var id eDims     -> do
        t <- lookupVar id
        typedEDims <- mapM (checkTypeExpr Int) (dimsToExprs eDims)
        let tExpr = case t of
                      DimT t' dims -> DimT t' (dims - fromIntegral (length eDims))
                      _            -> t
        return $ ETyped (Var id (exprsToDims typedEDims)) tExpr
      EArrL id eDims    -> do
        (DimT t ndims) <- lookupVar id
        when (length' eDims > ndims) $ fail "Indexing failure: Too many dimensions"
        typedEDims <- mapM (checkTypeExpr Int) (dimsToExprs eDims)
        return (ETyped (EArrL id (exprsToDims typedEDims)) Int)
      EArrI t eDims     -> do
        let ndims = fromIntegral $ length eDims
        typedEDims <- mapM (checkTypeExpr Int) (dimsToExprs eDims)
        checkValidArrayType t
        return (ETyped (EArrI t (exprsToDims typedEDims)) (DimT t ndims))
      EString s        -> return $ ETyped exp String
      EApp id args     -> do
        (args_type, ret_type) <- lookupFun id 
        typedArgs <- checkArgs id args_type args
        return $ ETyped (EApp id typedArgs) ret_type
      EMul exp1 op exp2  -> do
        typedE1@(ETyped _ t1)  <- inferTypeExpr exp1
        checkTypeNum t1 
        typedE2 <- checkTypeExpr t1 exp2
        return $ ETyped (EMul typedE1 op typedE2) t1 
      EAdd exp1 op exp2  -> do
        typedE1@(ETyped _ t1)  <- inferTypeExpr exp1
        checkTypeNum t1 
        typedE2 <- checkTypeExpr t1 exp2
        return $ ETyped (EAdd typedE1 op typedE2)  t1 
      ERel exp1 op exp2    -> do
        t <- inferTypeCMP exp1 exp2
        typedE1 <- inferTypeExpr exp1
        typedE2 <- inferTypeExpr exp2
        return $ ETyped (ERel typedE1 op typedE2) t
      
      EAnd exp1 exp2   -> do 
        typedE1 <- checkTypeExpr Bool exp1
        typedE2 <- checkTypeExpr Bool exp2
        return $ ETyped (EAnd typedE1 typedE2) Bool
      EOr exp1 exp2    -> do 
        typedE1 <- checkTypeExpr Bool exp1
        typedE2 <- checkTypeExpr Bool exp2
        return $ ETyped (EOr typedE1 typedE2) Bool
      Not exp          -> do
        typedExpr <- checkTypeExpr Bool exp
        return $ ETyped (Not typedExpr) Bool
      Neg exp          -> do
        typedExpr@(ETyped _ t) <- inferTypeExpr exp
        checkTypeNum t
        return $ ETyped (Neg typedExpr) t

-- | Checks if a type is suitable to be contained in an array.
checkValidArrayType :: Type -> TypeCheck () 
checkValidArrayType Void        = fail "Cannot create an array of voids."
checkValidArrayType (Array _ _) = fail "Cannot create an array of arrays."
checkValidArrayType _         = return ()


-- | Check the type of a numeric expression. If its neither Int or Double error.
checkTypeNum :: Type -> TypeCheck Type
checkTypeNum t@Int    = return t
checkTypeNum t@Doub   = return t
checkTypeNum t@(DimT Int 0)    = return t
checkTypeNum t@(DimT Doub 0)   = return t
checkTypeNum t                 = fail $ "Expected type Int or Double, actual type: " ++ show t

-- | Check that the arguments to a function call correspond on type and number as 
-- | function signature.
checkArgs :: Ident -> [Type] -> [Expr] -> TypeCheck [Expr]
checkArgs _ [] []  = return []
checkArgs ide _  [] = fail $ 
  "Diferent number of arguments from declared in function " ++ show ide
checkArgs ide [] _  = fail $ 
  "Diferent number of arguments from declared in function " ++ show ide
checkArgs ide (e_t:xs) (c_t:ys) = do
  typedExpr <- checkTypeExpr e_t  c_t 
  otherTypedExpr <- checkArgs ide xs ys
  return $ typedExpr : otherTypedExpr

-- | Infer the type of a comparison operator.
inferTypeCMP :: Expr -> Expr -> TypeCheck Type
inferTypeCMP exp1 exp2 = do
    (ETyped _ t1) <- inferTypeExpr exp1
    checkVoid t1
    (ETyped _ t2) <- inferTypeExpr exp2
    checkVoid t2
    if typeEq t1 t2 then return Bool
    else
      fail $ "Cannot compare type " ++ show t1
                                   ++ " with type " ++ show t2
      where
        checkVoid t = when (typeEq t Void)$ fail "Void is not comparable." 

