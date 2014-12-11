--
-- Copyright 2014, NICTA
--
-- This software may be distributed and modified according to the terms of
-- the BSD 2-Clause license. Note that NO WARRANTY is provided.
-- See "LICENSE_BSD2.txt" for details.
--
-- @TAG(NICTA_BSD)
--

module CapDL.MakeModel where

import CapDL.Model
import CapDL.AST
import CapDL.State

import Data.Word
import Data.Maybe
import Data.List
import Data.List.Ordered
import Data.Either as Either
import Data.Data
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Control.Monad.State as ST
import Control.Monad

type SlotState = ST.State Word

getSlot :: SlotState Word
getSlot = do
    slot <- ST.get
    return $ slot + 1

putSlot :: Word -> SlotState ()
putSlot = ST.put

isUntyped :: KernelObject Word -> Bool
isUntyped (Untyped {}) = True
isUntyped _ = False

emptyModel arch = Model arch Map.empty Map.empty
emptyIdents = Idents Map.empty

printID :: ObjID -> String
printID (name, Nothing) = name
printID (name, Just num) = name ++ "[" ++ show num ++ "]"

baseName :: QName -> NameRef
baseName = last

qNames :: QName -> [NameRef]
qNames = init

sameName :: ObjID -> ObjID -> Bool
sameName (first, _) (second, _) = first == second

numObject :: Map.Map ObjID a -> Name -> Word
numObject objs name =
    if Map.member (name, Just 0) objs
    then fromIntegral $ length $ filter (sameName (name, Nothing)) $ Map.keys objs
    else error $ "Unknown reference: " ++ name

refToID :: NameRef -> ObjID
refToID (name, []) = (name, Nothing)
refToID (name, [Only n]) = (name, Just n)
refToID names = error ("A unique identifer was expected at " ++ show names)

unrange :: Word -> Range -> [Maybe Word]
unrange num range = case range of
    Only id -> [Just id]
    FromTo first last -> map Just list
        where list = if first <= last
                     then [first..last]
                     else [first,first-1..last]
    From first -> map Just [first..num - 1]
    To last -> map Just [0..last]
    All -> map Just [0..num - 1]

refToIDs :: Map.Map ObjID a -> NameRef -> [ObjID]
refToIDs _ (name, []) = [(name, Nothing)]
refToIDs objs (name, ranges) =
    zip (repeat name) $ concatMap (unrange (numObject objs name)) ranges

makeIDs :: Name -> Maybe Word -> [ObjID]
makeIDs name Nothing = [(name,Nothing)]
makeIDs name (Just num) = zip (repeat name) (map Just [0..(num - 1)])

members :: Ord k => [k] -> Map.Map k a -> Bool
members names objs = all (flip Map.member objs) names

addCovered :: ObjMap Word -> [ObjID] -> ObjSet -> ObjSet
addCovered objs names cov =
    if members names objs
    then foldl' (flip Set.insert) cov names
    else error ("At least one object reference is unknown: " ++ show names)

getUTCov :: CoverMap -> ObjID -> ObjSet
getUTCov covers ut =
    case Map.lookup ut covers of
        Nothing -> Set.empty
        Just cov -> cov

addUTCover :: ObjMap Word -> CoverMap -> [ObjID] -> ObjID -> CoverMap
addUTCover objs covers names ut =
    let cov = getUTCov covers ut
    in Map.insert ut (addCovered objs names cov) covers

addUTCovers :: ObjMap Word -> CoverMap -> [ObjID] -> [ObjID] -> CoverMap
addUTCovers _ covers _ [] = covers
addUTCovers objs covers n [ut] = addUTCover objs covers n ut
addUTCovers objs covers n (ut:uts) =
    addUTCovers objs (addUTCover objs covers n ut) [ut] uts

addUTDecl ::  ObjMap Word -> ObjID -> CoverMap -> NameRef -> CoverMap
addUTDecl objs ut covers names = addUTCover objs covers (refToIDs objs names) ut

addUTDecls ::  ObjMap Word -> ObjID -> CoverMap -> [NameRef] -> CoverMap
addUTDecls objs ut = foldl' (addUTDecl objs ut)

getUntypedCover :: [NameRef] -> ObjMap Word -> CoverMap -> Decl -> CoverMap
getUntypedCover ns objs covers (ObjDecl (KODecl objName obj)) =
    if null (objDecls obj)
    then
        let (name, num) = refToID $ baseName objName
            qns = qNames objName
        in addUTCovers objs covers (makeIDs name num)
                       (map refToID (reverse (ns ++ qns)))
    else
        let name = refToID $ baseName objName
            qns = qNames objName
            covers' = addUTCovers objs covers [name]
                                  (map refToID (reverse (ns ++ qns)))
            covers'' = addUTDecls objs name covers (Either.rights (objDecls obj))
        in getUntypedCovers (ns ++ objName) objs covers''
                                        (map ObjDecl (lefts (objDecls obj)))
getUntypedCover _ _ covers _ = covers

getUntypedCovers :: [NameRef] -> ObjMap Word -> CoverMap -> [Decl] -> CoverMap
getUntypedCovers ns objs =
    foldl' (getUntypedCover ns objs)

emptyUntyped :: KernelObject Word
emptyUntyped = Untyped Nothing

getUTObj :: ObjMap Word -> ObjID -> KernelObject Word
getUTObj objs ut =
    case Map.lookup ut objs of
        Nothing -> emptyUntyped
        Just obj ->
            if isUntyped obj
            then obj
            else error ("Untyped object expected at \""++ printID ut ++
                        "\", but found instead: " ++ show obj)

addUTName :: ObjMap Word -> ObjID -> ObjMap Word
addUTName objs ut = Map.insert ut (getUTObj objs ut) objs

addUTNames :: ObjMap Word -> [ObjID] -> ObjMap Word
addUTNames objs [] = objs
addUTNames objs [ut] = addUTName objs ut
addUTNames objs (ut:uts) = addUTNames (addUTName objs ut) uts

addUntyped :: ObjMap Word -> Decl -> ObjMap Word
addUntyped objs (ObjDecl (KODecl objName obj)) =
    if null (objDecls obj)
    then
        let qns = qNames objName
        in addUTNames objs (map refToID qns)
    else
        let qns = qNames objName
            objs' = addUTNames objs (map refToID qns)
        in addUntypeds objs' (map ObjDecl (lefts (objDecls obj)))
addUntyped objs _ = objs

addUntypeds :: ObjMap Word -> [Decl] -> ObjMap Word
addUntypeds = foldl' addUntyped


getTCBAddr :: [ObjParam] -> Maybe Word
getTCBAddr [] = Nothing
getTCBAddr (TCBExtraParam (Addr addr) : xs) = Just addr
getTCBAddr (_ : xs ) = getTCBAddr xs

getTCBip :: [ObjParam] -> Maybe Word
getTCBip [] = Nothing
getTCBip (TCBExtraParam (IP ip) : xs) = Just ip
getTCBip (_ : xs ) = getTCBip xs

getTCBsp :: [ObjParam] -> Maybe Word
getTCBsp [] = Nothing
getTCBsp (TCBExtraParam (SP sp) : xs) = Just sp
getTCBsp (_ : xs ) = getTCBsp xs

getTCBelf :: [ObjParam] -> Maybe String
getTCBelf [] = Nothing
getTCBelf (TCBExtraParam (Elf elf) : xs) = Just elf
getTCBelf (_ : xs ) = getTCBelf xs

getTCBprio :: [ObjParam] -> Maybe Integer
getTCBprio [] = Nothing
getTCBprio (TCBExtraParam (Prio prio) : xs) = Just prio
getTCBprio (_ : xs) = getTCBprio xs

getTCBmax_prio :: [ObjParam] -> Maybe Integer
getTCBmax_prio [] = Nothing
getTCBmax_prio (TCBExtraParam (MaxPrio max_prio) : xs) = Just max_prio
getTCBmax_prio (_ : xs) = getTCBmax_prio xs

getTCBcrit :: [ObjParam] -> Maybe Integer
getTCBcrit [] = Nothing
getTCBcrit (TCBExtraParam (Crit crit) : xs) = Just crit
getTCBcrit (_ : xs) = getTCBcrit xs

getTCBmax_crit :: [ObjParam] -> Maybe Integer
getTCBmax_crit [] = Nothing
getTCBmax_crit (TCBExtraParam (MaxCrit max_crit) : xs) = Just max_crit
getTCBmax_crit (_ : xs) = getTCBmax_crit xs

getExtraInfo :: Name -> [ObjParam] -> Maybe TCBExtraInfo
getExtraInfo n params =
    -- FIXME: This is really hacky hardcoding the acceptable combinations of attributes.
    case (getTCBAddr params, getTCBip params, getTCBsp params, getTCBelf params, getTCBprio params) of
        (Just addr, Just ip, Just sp, Just elf, Just prio) ->
            Just $ TCBExtraInfo addr (Just ip) (Just sp) (Just elf) (Just prio) Nothing Nothing Nothing
        (Just addr, Just ip, Just sp, Nothing, Just prio) ->
            Just $ TCBExtraInfo addr (Just ip) (Just sp) Nothing (Just prio) Nothing Nothing Nothing
        (Just addr, Nothing, Nothing, Nothing, Nothing) ->
            Just $ TCBExtraInfo addr Nothing Nothing Nothing Nothing Nothing Nothing Nothing
        (Nothing, Nothing, Nothing, Nothing, Nothing) -> Nothing
        params -> error $ "Incorrect extra tcb parameters: " ++ n ++ show params

getTCBDom :: [ObjParam] -> Integer
getTCBDom [] = 0
getTCBDom (Dom dom : xs) = dom
getTCBDom (_ : xs) = getTCBDom xs

getInitArguments :: [ObjParam] -> [Word]
getInitArguments [] = []
getInitArguments (InitArguments init : xs) = init
getInitArguments (_ : xs) = getInitArguments xs

getSCperiod :: [ObjParam] -> Maybe Word
getSCperiod [] = Nothing
getSCperiod (SCExtraParam (Period period) : xs) = Just period
getSCperiod (_ : xs) = getSCperiod xs

getSCdeadline :: [ObjParam] -> Maybe Word
getSCdeadline [] = Nothing
getSCdeadline (SCExtraParam (Deadline deadline) : xs) = Just deadline
getSCdeadline (_ : xs) = getSCdeadline xs

getSCexec_req :: [ObjParam] -> Maybe Word
getSCexec_req [] = Nothing
getSCexec_req (SCExtraParam (ExecReq exec_req) : xs) = Just exec_req
getSCexec_req (_ : xs) = getSCexec_req xs

getSCflags :: [ObjParam] -> Maybe Integer
getSCflags [] = Nothing
getSCflags (SCExtraParam (Flags flags) : xs) = Just flags
getSCflags (_ : xs) = getSCflags xs

getSCExtraInfo :: Name -> [ObjParam] -> Maybe SCExtraInfo
getSCExtraInfo n params =
    -- FIXME: This is really hacky hardcoding the acceptable combinations of attributes.
    case (getSCperiod params, getSCdeadline params, getSCexec_req params, getSCflags params) of
        (Just period, Just deadline, Just exec_req, Just flags) ->
            Just $ SCExtraInfo (Just period) (Just deadline) (Just exec_req) (Just flags)
        (Just period, Just deadline, Just exec_req, Nothing) ->
            Just $ SCExtraInfo (Just period) (Just deadline) (Just exec_req) Nothing 
        (Nothing, Nothing, Nothing, Nothing) -> Nothing
        params -> error $ "Incorrect extra sc parameters: " ++ n ++ show params

getMaybeBitSize :: [ObjParam] -> Maybe Word
getMaybeBitSize [] = Nothing
getMaybeBitSize (BitSize x : xs) = Just x
getMaybeBitSize (_ : xs) = getMaybeBitSize xs

getBitSize :: Name -> [ObjParam] -> Word
getBitSize n xs =
    case getMaybeBitSize xs of
        Nothing -> error ("Needs bitsize parameter: " ++ n)
        Just sz -> sz

getVMSize :: Name -> [ObjParam] -> Word
getVMSize n [] = error ("Needs vmsize parameter: " ++ n)
getVMSize n (VMSize x : xs) = x
getVMSize n (_ : xs) = getVMSize n xs

getMaybePaddr :: [ObjParam] -> Maybe Word
getMaybePaddr [] = Nothing
getMaybePaddr (Paddr x : xs) = Just x
getMaybePaddr (_ : xs) = getMaybePaddr xs

getLevel :: Name -> [ObjParam] -> Word
getLevel n [] = error ("Needs level parameter: " ++ n)
getLevel n (IOPTLevel l : xs) = l
getLevel n (_ : xs) = getLevel n xs

getPortsSize :: [ObjParam] -> Word
getPortsSize [] = 64 * (2^10)
getPortsSize (PortsSize x : xs) = x
getPortsSize (_ : xs) = getPortsSize xs

getDomainID :: Name -> [ObjParam] -> Word
getDomainID n [] = error ("Needs domainID parameter: " ++ n)
getDomainID n (DomainID x : xs) = x
getDomainID n (_ : xs) = getDomainID n xs

getPCIDevice :: Name -> [ObjParam] -> (Word, Word, Word)
getPCIDevice n [] = error ("Needs pciDevice parameter: " ++ n)
getPCIDevice n (PCIDevice x : xs) = x
getPCIDevice n (_ : xs) = getPCIDevice n xs

orderedSubset :: Eq a => [a] -> [a] -> Bool
orderedSubset [] _ = True
orderedSubset _ [] = False
orderedSubset (x:xs) (y:ys)
    | x == y = orderedSubset xs ys
    | otherwise = orderedSubset (x:xs) ys

sortConstrs :: (Data a, Ord a) => a -> a -> Ordering
sortConstrs x y =
  if toConstr x == toConstr y
     then EQ
     else compare x y

subsetConstrs :: (Data a, Ord a) => [a] -> [a] -> Bool
subsetConstrs xs ys = orderedSubset (map toConstr $ sortBy sortConstrs xs)
                                    (map toConstr $ sortBy sortConstrs ys)

containsConstr :: (Data b) => b -> [b] -> Bool
containsConstr x xs = toConstr x `elem` map toConstr xs

numConstrs :: (Data a) => a -> Int
numConstrs x = length $ dataTypeConstrs $ dataTypeOf x

removeConstr :: Data a => a -> [a] -> [a]
removeConstr x xs = filter (\y -> toConstr x /= toConstr y) xs

validObjPars :: KO -> Bool
validObjPars (Obj TCB_T ps []) =
  subsetConstrs ps (replicate (numConstrs (Addr undefined)) (TCBExtraParam undefined) 
                    ++ [InitArguments undefined, Dom undefined])
validObjPars (Obj CNode_T ps []) = subsetConstrs ps [BitSize undefined]
validObjPars (Obj Untyped_T ps ds) = subsetConstrs ps [BitSize undefined]
validObjPars (Obj Frame_T ps []) =
  subsetConstrs ps [VMSize undefined, Paddr undefined] &&
  (not (containsConstr (Paddr undefined) ps) || containsConstr (VMSize undefined) ps)
validObjPars (Obj IOPT_T ps []) = subsetConstrs ps [IOPTLevel undefined]
validObjPars (Obj IOPorts_T ps []) = subsetConstrs ps [PortsSize undefined]
validObjPars (Obj IODevice_T ps []) = subsetConstrs ps [DomainID undefined, PCIDevice undefined]
validObjPars (Obj SC_T ps []) = 
  subsetConstrs ps (replicate (numConstrs (Addr undefined)) (SCExtraParam undefined))
validObjPars obj = null (params obj)

objectOf :: Name -> KO -> KernelObject Word
objectOf n obj =
    if validObjPars obj
    then case obj of
        Obj Endpoint_T [] [] -> Endpoint
        Obj AsyncEndpoint_T [] [] -> AsyncEndpoint
        Obj TCB_T ps [] -> TCB Map.empty (getExtraInfo n ps) (getTCBDom ps) (getInitArguments ps)
        Obj CNode_T ps [] -> CNode Map.empty (getBitSize n ps)
        Obj Untyped_T ps ds -> Untyped (getMaybeBitSize ps)
        Obj ASIDPool_T ps [] -> ASIDPool Map.empty
        Obj PT_T ps [] -> PT Map.empty
        Obj PD_T ps [] -> PD Map.empty
        Obj Frame_T ps [] -> Frame (getVMSize n ps) (getMaybePaddr ps)
        Obj IOPT_T ps [] -> IOPT Map.empty (getLevel n ps)
        Obj IOPorts_T ps [] -> IOPorts (getPortsSize ps)
        Obj IODevice_T ps [] -> IODevice Map.empty (getDomainID n ps) (getPCIDevice n ps)
        Obj IrqSlot_T [] [] -> CNode Map.empty 0
        Obj VCPU_T [] [] -> VCPU
	Obj SC_T ps [] -> SC (getSCExtraInfo n ps)
        Obj t ps (d:ds) ->
          error $ "Only untyped caps can have objects as content: " ++
                  n ++ " = " ++ show obj
        _ -> error ("Could not convert: " ++ n ++ " = " ++ show obj)
    else error ("Incorrect params for " ++ n)

insertObjects :: [ObjID] -> KernelObject Word -> ObjMap Word -> ObjMap Word
insertObjects ids obj objs = foldl' (\map id->Map.insert id obj map) objs ids

isMember :: Name -> ObjMap Word -> Bool
isMember name objs =
    Map.member (name, Nothing) objs || Map.member (name, Just 0) objs

addObject :: ObjMap Word -> Decl -> ObjMap Word
addObject objs (ObjDecl (KODecl objName obj)) =
    if not $ CapDL.AST.koType obj == Untyped_T && isMember name objs
    then if isMember name objs
        then error ("Duplicate name declaration: " ++ name)
        else let
            objs' = insertObjects (makeIDs name num) (objectOf name obj) objs
        in addObjects objs' (map ObjDecl (lefts (objDecls obj)))
    else objs
    where (name, num) = refToID $ baseName objName
addObject s _ = s

addObjects :: ObjMap Word -> [Decl] -> ObjMap Word
addObjects = foldl' addObject

addIRQ :: IRQMap -> (Word, ObjID) -> IRQMap
addIRQ irqNode (slot, irq) =
    if Map.member slot irqNode
    then error ("IRQ already mapped: " ++ show slot)
    else Map.insert slot irq irqNode

addIRQs :: IRQMap -> [(Word, ObjID)] -> IRQMap
addIRQs = foldl' addIRQ

getSlotIRQs :: ObjMap Word -> CapMapping -> SlotState [(Word, ObjID)]
getSlotIRQs objs (IRQMapping slot nameRef) = do
    slot' <- checkSlot slot
    let irqs = refToIDs objs nameRef
        lastSlot = slot' + fromIntegral (length irqs - 1)
    putSlot lastSlot
    return $ zip [slot'..lastSlot] irqs

addIRQMapping :: ObjMap Word -> SlotState IRQMap -> CapMapping -> SlotState IRQMap
addIRQMapping objs irqNode cm = do
    slotIRQs <- getSlotIRQs objs cm
    node <- irqNode
    return $ addIRQs node slotIRQs

addIRQMappings :: ObjMap Word -> IRQMap -> [CapMapping] -> SlotState IRQMap
addIRQMappings objs irqNode =
    foldl' (addIRQMapping objs) (return irqNode)

addIRQNode :: ObjMap Word -> IRQMap -> Decl -> IRQMap
addIRQNode objs irqNode (IRQDecl irqs) =
    if Map.null irqNode
    then ST.evalState (addIRQMappings objs irqNode irqs) (-1)
    else error "Duplicate IRQ node declaration"
addIRQNode _ irqNode _ = irqNode

addIRQNodes :: ObjMap Word -> IRQMap -> [Decl] -> IRQMap
addIRQNodes objs = foldl' (addIRQNode objs)

insertMapping :: KernelObject Word -> (Word, Cap) -> KernelObject Word
insertMapping obj (slot, cap) =
    if hasSlots obj
    then let mappings = slots obj
        in if Map.member slot mappings
        then error ("Slot already filled: " ++ show slot)
        else obj {slots = Map.insert slot cap mappings}
    else error ("This object does not support cap mappings: " ++ show obj)

insertMappings :: KernelObject Word -> [(Word, Cap)] -> KernelObject Word
insertMappings = foldl' insertMapping

getBadge :: [CapParam] -> Word
getBadge [] = 0
getBadge (Badge n : _) = n
getBadge (_ : xs) = getBadge xs

getRights :: [CapParam] -> CapRights
getRights [] = Set.empty
getRights (Rights r : ps) = r `Set.union` getRights ps
getRights (_ : ps) = getRights ps

getGuard :: [CapParam] -> Word
getGuard [] = 0
getGuard (Guard n : ps) = n
getGuard (_ : ps) = getGuard ps

getGuardSize :: [CapParam] -> Word
getGuardSize [] = 0
getGuardSize (GuardSize n : ps) = n
getGuardSize (_ : ps) = getGuardSize ps

getPorts :: ObjID -> [CapParam] -> Word -> Set.Set Word
getPorts containerName [] _ =
    error ("io_ports cap in " ++ printID containerName ++ " needs a range")
getPorts containerName (Range r:_) size =
    if maximum list >= size || minimum list < 0
    then error ("A cap in " ++ printID containerName ++
                " refers to a non-existent IO port")
    else Set.fromList list
    where list = concatMap (catMaybes . unrange size) r
getPorts containerName (_:ps) size = getPorts containerName ps size

getReplys :: [CapParam] -> [CapParam]
getReplys [] = []
getReplys (Reply : ps) = Reply : getReplys ps
getReplys (MasterReply : ps) = MasterReply : getReplys ps
getReplys (_ : ps) = getReplys ps

hasPorts :: [CapParam] -> Bool
hasPorts [] = False
hasPorts (Range _ : ps) = True
hasPorts (_ : ps) = hasPorts ps

getMaybeAsid :: [CapParam] -> Maybe Asid
getMaybeAsid [] = Nothing
getMaybeAsid (Asid asid : ps) = Just asid
getMaybeAsid (_ : ps) = getMaybeAsid ps

getAsid :: ObjID -> ObjID -> [CapParam] -> Asid
getAsid containerName objRef ps = 
    case getMaybeAsid ps of
        Nothing -> error ("Needs asid parameter for cap to " ++ printID objRef ++
                          " in " ++ printID containerName)
        Just asid -> asid

getCached :: [CapParam] -> Bool
getCached [] = True
getCached (Cached c : ps) = c
getCached (_ : ps) = getCached ps

validCapPars :: KernelObject Word -> [CapParam] -> Bool
validCapPars (Endpoint {}) ps =
    subsetConstrs (removeConstr (Rights undefined) ps) [Badge undefined]
validCapPars (AsyncEndpoint {}) ps =
    subsetConstrs (removeConstr (Rights undefined) ps) [Badge undefined]
validCapPars (TCB {}) ps =
    subsetConstrs ps [Reply, MasterReply] &&
    (not (containsConstr Reply ps) || not (containsConstr MasterReply ps))
validCapPars (CNode {}) ps = subsetConstrs ps [Guard undefined, GuardSize undefined]
validCapPars (Frame {}) ps =
    subsetConstrs (removeConstr (Rights undefined) ps) [Asid undefined, Cached undefined]
validCapPars (PD {}) ps = subsetConstrs ps [Asid undefined]
validCapPars (PT {}) ps = subsetConstrs ps [Asid undefined]
validCapPars (ASIDPool {}) ps = subsetConstrs ps [Asid undefined]
validCapPars (IOPorts {}) ps = subsetConstrs ps [Range undefined]
validCapPars _ ps = null ps

objCapOf :: ObjID -> KernelObject Word -> ObjID -> [CapParam] -> Cap
objCapOf containerName obj objRef params =
    if validCapPars obj params
    then case obj of
        Endpoint -> EndpointCap objRef (getBadge params) (getRights params)
        AsyncEndpoint ->
            AsyncEndpointCap objRef (getBadge params) (getRights params)
        TCB {} ->
            case getReplys params of
                [] -> TCBCap objRef
                [Reply] -> ReplyCap objRef
                [MasterReply] -> MasterReplyCap objRef
        Untyped {} -> UntypedCap objRef
        CNode _ 0 -> IRQHandlerCap objRef --FIXME: This should check if the obj is in the irqNode
        CNode {} -> CNodeCap objRef (getGuard params) (getGuardSize params)
        Frame {} -> FrameCap objRef (getRights params) (getMaybeAsid params) (getCached params)
        PD {} -> PDCap objRef (getMaybeAsid params)
        PT {} -> PTCap objRef (getMaybeAsid params)
        ASIDPool {} -> ASIDPoolCap objRef (getAsid containerName objRef params)
        IOPT {} -> IOPTCap objRef
        IOPorts size -> IOPortsCap objRef (getPorts containerName params size)
        IODevice {} -> IOSpaceCap objRef
        VCPU {} -> VCPUCap objRef
	SC {} -> SCCap objRef
    else error ("Incorrect params for cap to " ++ printID objRef ++ " in " ++
                printID containerName)

capOf :: ObjMap Word -> ObjID -> [CapParam] -> ObjID -> Cap
capOf objs containerName xs id =
    case Map.lookup id objs of
        Nothing ->
            error ("Unknown object \"" ++ printID id ++
                   "\" for cap in " ++ printID containerName)
        Just obj -> objCapOf containerName obj id xs

capsOf :: ObjMap Word -> ObjID -> [ObjID] -> [CapParam] -> [Cap]
capsOf objs name ids xs = map (capOf objs name xs) ids

checkSlot :: Maybe Word -> SlotState Word
checkSlot (Just slot) = return slot
checkSlot Nothing = getSlot

slotsAndCapsOf :: ObjMap Word-> ObjID -> CapMapping -> SlotState [(Word, Cap)]
slotsAndCapsOf objs objName (CapMapping slot _ nameRef params _)
    | (nameRef, params) == ((ioSpaceMaster, []), []) = do
        slot' <- checkSlot slot
        putSlot slot'
        return [(slot', IOSpaceMasterCap)]
    | (nameRef, params) == ((asidControl, []), []) = do
        slot' <- checkSlot slot
        putSlot slot'
        return [(slot', ASIDControlCap)]
    | (nameRef, params) == ((irqControl, []), []) = do
        slot' <- checkSlot slot
        putSlot slot'
        return [(slot', IRQControlCap)]
    | (nameRef, params) == ((domain, []), []) = do
        slot' <- checkSlot slot
        putSlot slot'
        return [(slot', DomainCap)]
    | (nameRef, params) == ((schedControl, []), []) = do
        slot' <- checkSlot slot
        putSlot slot'
        return [(slot', SchedControlCap)]
    | otherwise = do
        slot' <- checkSlot slot
        let caps = capsOf objs objName (refToIDs objs nameRef) params
            lastSlot = slot' + fromIntegral (length caps - 1)
        putSlot lastSlot
        return $ zip [slot'..lastSlot] caps
slotsAndCapsOf _ _ (CopyOf slot nm ref _ _) = do
    slot' <- checkSlot slot
    putSlot slot'
    return [(slot', NullCap)]

addMapping :: ObjMap Word -> ObjID -> KernelObject Word -> CapMapping
              -> SlotState (KernelObject Word)
addMapping objs n obj cm = do
    slotCaps <- slotsAndCapsOf objs n cm
    return $ insertMappings obj slotCaps

addMappings :: ObjMap Word -> ObjID -> KernelObject Word -> [CapMapping]
               -> SlotState (KernelObject Word)
addMappings objs n =
    foldM (addMapping objs n)

hasUnnumbered :: [CapMapping] -> Bool
hasUnnumbered [] = False
hasUnnumbered (x:xs) =
    case slot x of
        Nothing -> True
        _ -> hasUnnumbered xs

hasCopy :: [CapMapping] -> Bool
hasCopy [] = False
hasCopy (CopyOf {}:_) = True
hasCopy (_:xs) = hasCopy xs

validMapping :: [CapMapping] -> Bool
validMapping mappings = not $ hasCopy mappings && hasUnnumbered mappings

addCap :: Model Word -> (ObjID, [CapMapping]) -> Model Word
addCap (Model arch objs irqNode cdt untypedCovers) (id, mappings) =
    case Map.lookup id objs of
        Nothing -> error ("Unknown cap container: " ++ printID id)
        Just obj ->
            if validMapping mappings
            then Model arch (Map.insert id mapped objs) irqNode cdt untypedCovers
            else error $ printID id ++
                                " uses both copies of caps and unnumbered slots"
            where mapped = ST.evalState (addMappings objs id obj mappings) (-1)

addCapDecl :: Model Word -> Decl -> Model Word
addCapDecl m@(Model _ objs _ _ _) (CapDecl names mappings) =
    foldl' addCap m (zip (refToIDs objs names) (repeat mappings))
addCapDecl s _ = s

addCapDecls :: [Decl] -> Model Word -> Model Word
addCapDecls decls m = foldl' addCapDecl m decls

insertCapIdentMapping :: ObjID -> Idents CapName -> CapName -> Word
                         -> Idents CapName
insertCapIdentMapping obj (Idents ids) name slot =
    Idents (Map.insert name (obj,slot) ids)

addCapIdentMapping' :: ObjMap Word -> ObjID -> Idents CapName -> Word -> NameRef
                       -> NameRef -> Idents CapName
addCapIdentMapping' m obj ids slot (names, range) ref =
    let len = length $ refToIDs m ref
        names' = case range of
            [] -> if len == 1
                then [(names, Nothing)]
                else error ("Cannot give a unique name to an array of caps: "
                            ++ names)
            [All] -> zip (repeat names) (map Just [0..fromIntegral len - 1])
        lastSlot = slot + fromIntegral len - 1
        slots = [slot..lastSlot]
    in foldl' (\ids' (name, s) -> insertCapIdentMapping obj ids' name s)
                                                        ids (zip names' slots)

addCapIdentMapping :: ObjMap Word -> ObjID -> Idents CapName -> CapMapping
                      -> Idents CapName
addCapIdentMapping m obj ids (CapMapping (Just slot) (Just names) ref _ _) =
    addCapIdentMapping' m obj ids slot names ref
addCapIdentMapping m obj ids (CopyOf (Just slot) (Just names) ref _ _) =
    addCapIdentMapping' m obj ids slot names ref
addCapIdentMapping _ _ i _ = i

addCapIdentMappings :: ObjMap Word -> NameRef -> Idents CapName -> [CapMapping]
                       -> Idents CapName
addCapIdentMappings m obj =
    foldl' (addCapIdentMapping m (head (refToIDs m obj)))

addCapIdent :: ObjMap Word -> Idents CapName -> Decl -> Idents CapName
addCapIdent m (Idents ids) (CapNameDecl name target slot) =
    Idents (Map.insert (name, Nothing) (target', slot) ids)
    where
        target' = refToID target
addCapIdent m i (CapDecl obj mappings) = addCapIdentMappings m obj i mappings
addCapIdent _ i _ = i

capIdents :: ObjMap Word -> [Decl] -> Idents CapName
capIdents m = foldl' (addCapIdent m) emptyIdents


-- FIXME: inefficient, use a proper data structure for this
type CapRefMappings = CapRef -> Maybe CapRef

-- Follow a mapping transitively to the end
transMapping :: (Show a, Eq a) => (a -> Maybe a) -> a -> a
transMapping = transMappingE []

-- FIXME: I'm sure there is a library function for this somewhere
transMappingE :: (Show a, Eq a) => [a] -> (a -> Maybe a) -> a -> a
transMappingE seen m x =
    if x `elem` seen
        then error ("Cyclic reference: " ++ show x)
        else
            case m x of
                Nothing -> x
                Just l -> transMappingE (x:seen) m l

funUpd :: Eq a => (a -> b) -> a -> b -> a -> b
funUpd f x y z = if z == x then y else f z

empty :: a -> Maybe b
empty _ = Nothing

addCapCopyRef :: Idents CapName -> ObjID -> CapRefMappings ->
                 CapMapping -> CapRefMappings
addCapCopyRef (Idents ids) obj m (CopyOf (Just slot) _ target _ _) =
    funUpd m (obj, slot) (Map.lookup (refToID target) ids)
addCapCopyRef _ _ m _ = m

addCapCopyRefs :: ObjMap Word -> Idents CapName -> CapRefMappings -> Decl
                  -> CapRefMappings
addCapCopyRefs map ids m (CapDecl objs mappings) =
    foldl' (\m' obj -> foldl' (addCapCopyRef ids obj) m' mappings)
                                                          m (refToIDs map objs)
addCapCopyRefs _ _ m _ = m

capCopyGraph :: ObjMap Word -> Idents CapName -> [Decl] -> CapRefMappings
capCopyGraph m ids = foldl' (addCapCopyRefs m ids) empty

getMasked :: [CapParam] -> CapRights
getMasked [] = allRights
getMasked (Masked r : ps) = Set.intersection r (getMasked ps)
getMasked (_ : ps) = getMasked ps

copyCapParams :: [CapParam] -> Cap -> Cap
copyCapParams params cap
    | hasRights cap = cap {capRights = Set.intersection rights $ capRights cap}
    | otherwise = cap
    where rights = getMasked params

getSrcCap :: Idents CapName -> CapRefMappings -> Model Word -> ObjID -> Cap
getSrcCap (Idents ids) refs m src =
    case Map.lookup src ids of
        Nothing -> error ("Unknown cap reference: " ++ printID src)
        Just srcRef ->
            case maybeSlotCap (transMapping refs srcRef) m of
                Nothing -> error ("Could not resolve cap reference: "++
                                  show (transMapping refs srcRef))
                Just cap -> cap

addCapCopy :: Idents CapName -> CapRefMappings -> ObjID ->
              Model Word -> CapMapping -> Model Word
addCapCopy ids refs obj m (CopyOf (Just slot) _ src params _) =
    let caps = map (getSrcCap ids refs m) (refToIDs (cap_ids ids) src)
        slots = [slot..(slot + fromIntegral (length caps))]
        caps' = map (copyCapParams params) caps
    in foldl' (\m' (cap, slot') -> ST.execState (setCap (obj,slot') cap) m')
              m (zip caps' slots)
addCapCopy _ _ _ m _ = m

-- FIXME: this recursion pattern over all mappings is duplicated all over
-- the place. factor out.
addCapCopies :: Idents CapName -> CapRefMappings -> NameRef ->
              Model Word -> CapMapping -> Model Word
addCapCopies ids refs names m@(Model _ map _ _ _) copy =
    foldl' (\model obj -> addCapCopy ids refs obj model copy) m
          (refToIDs map names)

addCapCopyDecl :: Idents CapName -> CapRefMappings -> Model Word -> Decl ->
                  Model Word
addCapCopyDecl ids refs m (CapDecl obj mappings) =
    foldl' (addCapCopies ids refs obj) m mappings
addCapCopyDecl _ _ m _ = m

addCapCopyDecls :: Idents CapName -> CapRefMappings -> Model Word -> [Decl] ->
                   Model Word
addCapCopyDecls ids refs = foldl' (addCapCopyDecl ids refs)

getCapCopy :: Idents CapName -> ObjMap Word -> ObjID -> CopyMap ->
              CapMapping -> CopyMap
getCapCopy ids m obj copies (CopyOf (Just slot) _ src params _) =
    let capNames = refToIDs (cap_ids ids) src
        capRefs = zip (repeat obj) [slot..(slot + fromIntegral (length capNames))]
    in foldl' (\copies' (capRef, capName) -> Map.insert capRef capName copies')
                                                   copies (zip capRefs capNames)
getCapCopy _ _ _ m _ = m

getCapCopies :: Idents CapName -> ObjMap Word -> NameRef -> CopyMap ->
                CapMapping -> CopyMap
getCapCopies ids m names copies copy =
    foldl' (\copies obj -> getCapCopy ids m obj copies copy) copies
          (refToIDs m names)

getCapCopyDecl :: Idents CapName -> ObjMap Word -> CopyMap -> Decl -> CopyMap
getCapCopyDecl ids m copies (CapDecl obj mappings) =
    foldl' (getCapCopies ids m obj) copies mappings
getCapCopyDecl _ _ copies _ = copies

getCapCopyDecls :: Idents CapName -> ObjMap Word -> [Decl] -> CopyMap
getCapCopyDecls ids m = foldl' (getCapCopyDecl ids m) Map.empty

slotRefToCapRef :: Idents CapName -> SlotRef -> CapRef
slotRefToCapRef ids (Left (obj, slot)) = (refToID obj, slot)
slotRefToCapRef ids (Right name) =
    case Map.lookup (refToID name) (cap_ids ids) of
        Just capRef -> capRef
        Nothing -> error $ "Unknown cap reference: " ++ printID (refToID name)

insertCDT :: CapRef -> CapRef -> CDT -> CDT
insertCDT child parent cdt =
    if isNothing (Map.lookup child cdt)
    then Map.insert child parent cdt
    else error $ show child ++ " has multiple parents"

getDeclOrSlotRef :: Idents CapName -> CapRef -> CDT -> Either Decl SlotRef -> CDT
getDeclOrSlotRef ids parent cdt (Left decl@(CDTDecl child _)) =
    let child' = slotRefToCapRef ids child
        cdt' = insertCDT child' parent cdt
    in getCDTDecl ids cdt' decl
getDeclOrSlotRef ids parent cdt (Right child) =
    let child' = slotRefToCapRef ids child
    in insertCDT child' parent cdt

getCDTDecl :: Idents CapName -> CDT -> Decl -> CDT
getCDTDecl ids cdt (CDTDecl parent children) =
    foldl' (getDeclOrSlotRef ids parent') cdt children
    where parent' = slotRefToCapRef ids parent
getCDTDecl _ cdt _ = cdt

getCDTDecls :: Idents CapName -> [Decl] -> CDT
getCDTDecls ids = foldl' (getCDTDecl ids) Map.empty

addCDTMapping :: Idents CapName -> ObjID -> CDT -> CapMapping -> SlotState CDT
addCDTMapping ids obj cdt mapping
    | isJust (maybeParent mapping) = do
        slot' <- checkSlot (slot mapping)
        putSlot slot'
        let parent = slotRefToCapRef ids $ fromJust $ maybeParent mapping
            child = (obj, slot')
        return $ insertCDT child parent cdt
    | otherwise = return cdt

addCDTMappings :: Idents CapName -> CDT -> (ObjID, [CapMapping]) -> SlotState CDT
addCDTMappings ids cdt (obj, mappings) =
    foldM (addCDTMapping ids obj) cdt mappings

addCDTCapDecl :: ObjMap Word -> Idents CapName -> CDT -> Decl -> CDT
addCDTCapDecl objs ids cdt (CapDecl names mappings) =
    foldl' (\cdt capDecl -> ST.evalState (addCDTMappings ids cdt capDecl) (-1))
           cdt (zip (refToIDs objs names) (repeat mappings))
addCDTCapDecl _ _ cdt _ = cdt

addCDTCapDecls :: ObjMap Word -> Idents CapName -> CDT -> [Decl] -> CDT
addCDTCapDecls objs ids = foldl' (addCDTCapDecl objs ids)

makeModel :: Module -> (Model Word, Idents CapName, CopyMap)
makeModel (Module arch decls) =
    let objs = addObjects Map.empty decls
        objs' = addUntypeds objs decls
        irqs = addIRQNodes objs' Map.empty decls
        ids = capIdents objs' decls
        refs = capCopyGraph objs' ids decls
        copies = getCapCopyDecls ids objs' decls
        covers = getUntypedCovers [] objs' Map.empty decls
        cdt = getCDTDecls ids decls
        cdt' = addCDTCapDecls objs' ids cdt decls
    in (flip (addCapCopyDecls ids refs) decls .
        addCapDecls decls $ Model arch objs' irqs cdt' covers, ids, copies)
