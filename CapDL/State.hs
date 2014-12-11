--
-- Copyright 2014, NICTA
--
-- This software may be distributed and modified according to the terms of
-- the BSD 2-Clause license. Note that NO WARRANTY is provided.
-- See "LICENSE_BSD2.txt" for details.
--
-- @TAG(NICTA_BSD)
--

{-# LANGUAGE CPP #-}

module CapDL.State where

import CapDL.Model

import Control.Monad.State
import Control.Monad.Writer
import Data.Word
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.Set as Set
import Text.PrettyPrint

type Kernel a = State (Model Word) a

maybeObject :: ObjID -> Model Word -> Maybe (KernelObject Word)
maybeObject ref = Map.lookup ref . objects

isObject :: ObjID -> Model Word -> Bool
isObject ref = isJust . maybeObject ref

object :: ObjID -> Model Word -> KernelObject Word
object ref m =
    case maybeObject ref m of
        Just obj -> obj
        Nothing -> error $ "Object does not exist: " ++ show ref

setObject :: ObjID -> KernelObject Word -> Kernel ()
setObject ref obj = do
    modify (\s -> s { objects = Map.insert ref obj (objects s) })

modifyObject :: ObjID -> (KernelObject Word -> KernelObject Word) -> Kernel ()
modifyObject ref f = do
    obj <- gets $ object ref
    setObject ref (f obj)

objSlots :: KernelObject Word -> CapMap Word
objSlots obj =
    if hasSlots obj then slots obj
    else Map.empty

slotsOfMaybe :: Maybe (KernelObject Word) -> CapMap Word
slotsOfMaybe = maybe Map.empty objSlots

slotsOf :: ObjID -> Model Word -> CapMap Word
slotsOf ref = slotsOfMaybe . maybeObject ref

getCovered :: ObjID -> Model Word -> ObjSet
getCovered ut_ref (Model _ _ _ _ covers) =
    case Map.lookup ut_ref covers of
        Nothing -> Set.empty
        Just cov -> cov

setCovered :: ObjID -> ObjSet -> Kernel ()
setCovered ut_ref covers = do
    covMap <- gets untypedCovers
    let covMap' = Map.insert ut_ref covers covMap
    modify (\s -> s { untypedCovers = covMap' })

type SlotsLookup = ObjID -> Model Word -> CapMap Word

cNodeSlots :: SlotsLookup
cNodeSlots ref m = case maybeObject ref m of
    Just (CNode slots _) -> slots
    _ -> Map.empty

pdSlots :: SlotsLookup
pdSlots ref m = case maybeObject ref m of
    Just (PD slots) -> slots
    Just (PT slots) -> slots
    _ -> Map.empty

ioptSlots :: SlotsLookup
ioptSlots ref m = case maybeObject ref m of
    Just (IOPT slots _) -> slots
    _ -> Map.empty

maybeObjID :: Cap -> Maybe ObjID
maybeObjID cap = if hasObjID cap then Just (objID cap) else Nothing

lookupOf :: Cap -> SlotsLookup -> Model Word -> CapMap Word
lookupOf cap lookup = maybe (const Map.empty) lookup (maybeObjID cap)

type CapLookup = [([Word], Cap)]

singleton :: a -> [a]
singleton x = [x]

mapKeys :: (a -> b) -> [(a,c)] -> [(b,c)]
mapKeys f = map (\(a,b) -> (f a,b))

mapVals :: (b -> c) -> [(a,b)] -> [(a,c)]
mapVals f = map (\(a,b) -> (a,f b))

mapWithKey :: (a -> b -> c) -> [(a,b)] -> [c]
mapWithKey f = map (\(a,b) -> f a b)

snoc :: [a] -> a -> [a]
snoc xs x = xs ++ [x]

-- FIXME: ignoring guards
nextLookup :: Model Word -> SlotsLookup -> [Word] -> Cap -> CapLookup
nextLookup m lookup ws cap =
    Map.toList $ Map.mapKeys (snoc ws) (lookupOf cap lookup m)

-- FIXME: ignoring guards
nextLevel :: Model Word -> CapLookup -> SlotsLookup -> CapLookup
nextLevel m cl lookup = concat (mapWithKey (nextLookup m lookup) cl)

allLevels :: CapLookup -> Int -> SlotsLookup -> Model Word -> CapLookup
allLevels [] _ _ _ = []
allLevels _  0 _ _ = []
allLevels cl d lookup m =
    cl ++ allLevels (nextLevel m cl lookup) (d - 1) lookup m

maxDepth = 4

capSpaceLookup :: CapMap Word -> SlotsLookup -> Model Word -> CapLookup
capSpaceLookup caps lookup =
    let firstLevel = Map.toList . Map.mapKeys singleton $ caps
    in allLevels firstLevel maxDepth lookup

capSpace :: CapMap Word -> SlotsLookup -> Model Word -> CapMap [Word]
capSpace caps lookup = Map.fromList . capSpaceLookup caps lookup

cspaceCap :: ObjID -> Model Word -> Cap
cspaceCap tcb_ref =
    fromJust . Map.lookup tcbCTableSlot . slots . object tcb_ref

cspace :: ObjID -> Model Word -> CapMap [Word]
cspace tcb_ref m =
    let cap = cspaceCap tcb_ref m
    in capSpace (lookupOf cap cNodeSlots m) cNodeSlots m

capLookup :: [Word] -> ObjID -> Model Word -> Maybe Cap
capLookup ref tcb_ref = Map.lookup ref . cspace tcb_ref

flattenCnode :: KernelObject Word -> Model Word -> (ObjID, KernelObject [Word])
flattenCnode tcb m =
    let cnode_id = objID $ fromJust . Map.lookup tcbCTableSlot . slots $ tcb
        cnode = object cnode_id m
    in (cnode_id, cnode { slots = capSpace (slots cnode) cNodeSlots m })

flattenPD :: KernelObject Word -> Model Word -> KernelObject [Word]
flattenPD obj m =
    let newSlots = capSpace (slots obj) pdSlots m
        origSlots = Map.mapKeys singleton (slots obj)
    in obj { slots = Map.difference newSlots origSlots }

isFrame :: Cap -> Maybe Cap
isFrame cap =
    case cap of
        FrameCap {} -> Just cap
        _ -> Nothing

flattenIOPT :: KernelObject Word -> Model Word -> KernelObject [Word]
flattenIOPT obj m =
    let newSlots = capSpace (slots obj) ioptSlots m
        newSlots' = foldl (flip (Map.update isFrame)) newSlots $
                                                   map fst (Map.toList newSlots)
    in obj { slots = newSlots' }

flatten' :: Model Word -> ObjMap [Word] -> (ObjID, KernelObject Word) ->
            ObjMap [Word]
flatten' m objs (n, obj@(PD {})) = Map.insert n (flattenPD obj m) objs
flatten' m objs (n, obj@(IOPT _ 1)) = Map.insert n (flattenIOPT obj m) objs
flatten' m objs (n, obj@(TCB {})) =
    let tcb = obj { slots = Map.mapKeys singleton (slots obj) }
        objs' = Map.insert n tcb objs
        (cnode_id, cnode) = flattenCnode obj m
    in Map.insert cnode_id cnode objs'
flatten' m objs (n, obj)
    | hasSlots obj =
        let obj' = obj { slots = Map.mapKeys singleton (slots obj) }
        in Map.insertWith const n obj' objs
    | otherwise =
        let obj' = case obj of
                Endpoint -> Endpoint
                AsyncEndpoint -> AsyncEndpoint
                Untyped msb -> Untyped msb
                Frame vms p -> Frame vms p
                IOPorts sz -> IOPorts sz
        in Map.insert n obj' objs

flatten :: Model Word -> Model [Word]
flatten m@(Model arch objs irqNode cdt untypedCovers) =
    Model arch (foldl (flatten' m) Map.empty (Map.toList objs)) irqNode cdt untypedCovers


-- slots of one object
getSlots :: ObjID -> Kernel (CapMap Word)
getSlots ref = gets $ slotsOf ref

-- Caps

maybeSlotCap :: CapRef -> Model Word -> Maybe Cap
maybeSlotCap (ref,slot) = Map.lookup slot . slotsOf ref

slotCap :: CapRef -> Model Word -> Cap
slotCap cref = fromJust . maybeSlotCap cref

setSlots :: ObjID -> CapMap Word -> Kernel ()
setSlots ref sl = do
    obj <- gets $ object ref
    when (hasSlots obj) $ setObject ref $ obj {slots = sl}

setCap :: CapRef -> Cap -> Kernel ()
setCap (ref,slot) cap = do
    slots <- gets $ slotsOf ref
    case Map.lookup slot slots of
        Just NullCap -> setSlots ref $ Map.insert slot cap slots
        Nothing -> setSlots ref $ Map.insert slot cap slots
        _ -> error ("Slot already filled: slot " ++ show slot ++
                                          " in " ++ show ref)

removeCap :: CapRef -> Kernel ()
removeCap (ref,slot) = do
    slots <- gets $ slotsOf ref
    setSlots ref $ Map.delete slot slots

allObjs :: Model Word -> [(ObjID,KernelObject Word)]
allObjs = Map.toList . objects

refSlots :: (ObjID,KernelObject Word) -> [(CapRef, Cap)]
refSlots (ref,obj) =
    map (\(slot,cap) -> ((ref,slot),cap)) $ Map.toList $ objSlots obj

allSlots :: Model Word -> [(CapRef,Cap)]
allSlots = concatMap refSlots . allObjs

findSlotCapsWithRef :: (CapRef -> Cap -> Bool) -> Model Word -> [(CapRef, Cap)]
findSlotCapsWithRef p = filter (uncurry p) . allSlots

findSlotCaps :: (Cap -> Bool) -> Model Word -> [(CapRef, Cap)]
findSlotCaps p = findSlotCapsWithRef (\_ -> p)

findSlots :: (Cap -> Bool) -> Model Word -> [CapRef]
findSlots p = map fst . findSlotCaps p

hasTarget :: ObjID -> Cap -> Bool
hasTarget ref cap = if hasObjID cap then objID cap == ref else False

-- validity

#if __GLASGOW_HASKELL__<704

instance Monoid Doc where
    mempty = empty
    mappend x y = x $+$ y

#endif

type Logger a = Writer Doc a

sameID :: ObjID -> Cap -> Bool
sameID id cap = if hasObjID cap then id == objID cap else False

isMapped :: ObjID -> KernelObject Word -> Bool
isMapped id obj
    | hasSlots obj = or $ map (sameID id) $ Map.elems (slots obj)
    | otherwise = False

allMappings :: ObjID -> Model Word -> [(ObjID, KernelObject Word)]
allMappings id m = filter (isMapped id . snd) (allObjs m)

isASID :: KernelObject Word -> Bool
isASID (ASIDPool {}) = True
isASID _ = False

uniqueASID :: ObjID -> Model Word -> Bool
uniqueASID id m =
    let mappings = filter (isASID . snd) (allMappings id m)
    in length mappings <= 1

checkASID :: ObjID -> Model Word -> Logger Bool
checkASID id m = do
    let valid = uniqueASID id m
    unless valid (tell $ text $ show id ++ " is mapped into multiple ASID's")
    return valid

isPD :: KernelObject Word -> Bool
isPD (PD {}) = True
isPD _ = False

uniquePD :: ObjID -> Model Word -> Bool
uniquePD id m =
    let mappings = filter (isPD . snd) (allMappings id m)
    in length mappings <= 1

checkPD :: ObjID -> Model Word -> Logger Bool
checkPD id m = do
    let valid = uniquePD id m
    unless valid (tell $ text $ show id ++ " is mapped into multiple PD's")
    return valid

checkMapping :: Model Word -> (ObjID, KernelObject Word) -> Logger Bool
checkMapping m (id, obj) =
    case obj of
        PD {} -> checkASID id m
        PT {} -> checkPD id m
        _ -> return True

checkMappings :: Model Word -> Logger Bool
checkMappings m = do
    let objs = allObjs m
    allM (checkMapping m) objs

koType :: KernelObject Word -> KOType
koType Endpoint = Endpoint_T
koType AsyncEndpoint = AsyncEndpoint_T
koType (TCB {}) = TCB_T
koType (CNode {}) = CNode_T
koType (Untyped {}) = Untyped_T
koType (ASIDPool {}) = ASIDPool_T
koType (PD {}) = PD_T
koType (PT {}) = PT_T
koType (Frame {}) = Frame_T
koType (IOPorts {}) = IOPorts_T
koType (IODevice {}) = IODevice_T
koType (IOPT {}) = IOPT_T
koType (VCPU {}) = VCPU_T
koType (SC {}) = SC_T

objAt :: (KernelObject Word -> Bool) -> ObjID -> Model Word -> Bool
objAt p ref = maybe False p . maybeObject ref

typAt :: KOType -> ObjID -> Model Word -> Bool
typAt t = objAt $ (==) t . koType

capTyp :: Cap -> KOType
capTyp (UntypedCap {}) = Untyped_T
capTyp (EndpointCap {}) = Endpoint_T
capTyp (AsyncEndpointCap {}) = AsyncEndpoint_T
capTyp (ReplyCap {}) = TCB_T
capTyp (MasterReplyCap {}) = TCB_T
capTyp (CNodeCap {}) = CNode_T
capTyp (TCBCap {}) = TCB_T
capTyp IRQControlCap = CNode_T
capTyp (IRQHandlerCap {}) = CNode_T
capTyp (FrameCap {}) = Frame_T
capTyp (PTCap {}) = PT_T
capTyp (PDCap {}) = PD_T
capTyp (ASIDPoolCap {}) = ASIDPool_T
capTyp (IOPortsCap {}) = IOPorts_T
capTyp (IOSpaceCap {}) = IODevice_T
capTyp (IOPTCap {}) = IOPT_T
capTyp (VCPUCap {}) = VCPU_T
capTyp (SCCap {}) = SC_T
capTyp SchedControlCap = CNode_T

checkTypAt :: Cap -> Model Word -> ObjID -> Word -> Logger Bool
checkTypAt cap m contID slot = do
    let valid = if hasObjID cap then typAt (capTyp cap) (objID cap) m else True
    unless valid (tell $ text $ "The cap at slot " ++ show slot ++ " in " ++
                        show contID ++ " refers to an object of the wrong type") --FIXME:Needs better error message
    return valid

validCapArch :: Arch -> Cap -> Bool
validCapArch _ NullCap = True
validCapArch _ (UntypedCap {}) = True
validCapArch _ (EndpointCap {}) = True
validCapArch _ (AsyncEndpointCap {}) = True
validCapArch _ (ReplyCap {}) = True
validCapArch _ (MasterReplyCap {}) = True
validCapArch _ (CNodeCap {}) = True
validCapArch _ (TCBCap {}) = True
validCapArch _ IRQControlCap = True
validCapArch _ (IRQHandlerCap {}) = True
validCapArch _ (DomainCap {}) = True
validCapArch _ (FrameCap {}) = True
validCapArch _ (PTCap {}) = True
validCapArch _ (PDCap {}) = True
validCapArch _ (ASIDPoolCap {}) = True
validCapArch _ (SCCap {}) = True
validCapArch _ SchedControlCap = True
validCapArch IA32 (IOPortsCap {}) = True
validCapArch IA32 IOSpaceMasterCap = True
validCapArch IA32 (IOSpaceCap {}) = True
validCapArch IA32 (IOPTCap {}) = True
validCapArch IA32 (VCPUCap {}) = True
validCapArch _ _ = False

checkCapArch :: Arch -> Cap -> ObjID -> Word -> Logger Bool
checkCapArch arch cap contID slot = do
    let valid = validCapArch arch cap
    unless valid (tell $ text $ "The cap at slot " ++ show slot ++ " in " ++
                           show contID ++ " is not valid for this architecture")
    return valid

checkValidCap :: Arch -> ObjID -> Model Word -> (Word, Cap) -> Logger Bool
checkValidCap arch contID m (slot, cap) = do
    capArch <- checkCapArch arch cap contID slot
    typ <- checkTypAt cap m contID slot
    return $ capArch && typ

checkValidCaps :: Arch -> KernelObject Word -> ObjID -> Model Word -> Logger Bool
checkValidCaps arch obj id m =
    allM (checkValidCap arch id m) (Map.toList $ objSlots obj)

allM f xs = do
    bs <- mapM f xs
    return $ and bs

validObjArch :: Arch -> KernelObject Word -> Bool
validObjArch _ Endpoint = True
validObjArch _ AsyncEndpoint = True
validObjArch _ (TCB {}) = True
validObjArch _ (CNode {}) = True
validObjArch _ (Untyped {}) = True
validObjArch _ (ASIDPool {}) = True
validObjArch _ (PD {}) = True
validObjArch _ (PT {}) = True
validObjArch _ (Frame {}) = True
validObjArch _ (SC {}) = True
validObjArch IA32 (IOPorts {}) = True
validObjArch IA32 (IODevice {}) = True
validObjArch IA32 (IOPT {}) = True
validObjArch IA32 (VCPU {}) = True
validObjArch _ _ = False

checkObjArch :: Arch -> KernelObject Word -> ObjID -> Logger Bool
checkObjArch arch obj id = do
    let valid = validObjArch arch obj
    unless valid
     (tell $ text $ show id ++ " is not a valid object for this architecture")
    return valid

validObjCap :: KernelObject Word -> Cap -> Bool
validObjCap (CNode _ 0) (AsyncEndpointCap {}) = True --Should check if it is in the irqNode and in slot 0
validObjCap (CNode _ 0) _ = False
validObjCap (ASIDPool {}) (PDCap {}) = True
validObjCap (ASIDPool {}) _ = False
validObjCap (PT {}) (FrameCap {}) = True
validObjCap (PT {}) _ = False
validObjCap (PD {}) (FrameCap {}) = True
validObjCap (PD {}) (PTCap {}) = True
validObjCap (PD {}) _ = False
validObjCap (IOPT {}) (FrameCap {}) = True
validObjCap (IOPT {}) (IOPTCap {}) = True
validObjCap (IOPT {}) _ = False
validObjCap _ _ = True

checkValidSlot :: KernelObject Word -> ObjID -> (Word, Cap) -> Logger Bool
checkValidSlot obj contID (slot, cap) = do
    let valid = validObjCap obj cap
    unless valid (tell $ text $ "The cap at slot " ++ show slot ++ " in " ++
                           show contID ++ " is not valid for this object")
    return valid

checkValidSlots :: KernelObject Word -> ObjID -> Logger Bool
checkValidSlots (TCB slots _ _ _) id = return True --Do we want to check this?
checkValidSlots obj id =
    allM (checkValidSlot obj id) (Map.toList $ objSlots obj)

checkObj :: Arch -> Model Word -> (ObjID, KernelObject Word) -> Logger Bool
checkObj arch m (id, obj) = do
    objArch <- checkObjArch arch obj id
    caps <- checkValidCaps arch obj id m
    slots <- checkValidSlots obj id
    return $ objArch && caps && slots

checkObjs :: Arch -> Model Word -> Logger Bool
checkObjs arch m = do
    let objs = allObjs m
    allM (checkObj arch m) objs

allCovers :: Model Word -> [Set.Set ObjID]
allCovers (Model _ _ _ _ covMap) =
    let covers = map snd (Map.toList covMap)
    in filter (not . Set.null) covers

nullIntersections :: Ord a => [Set.Set a] -> Bool
nullIntersections [] = True
nullIntersections [x] = True
nullIntersections (x:xs) = Set.null (Set.intersection x (Set.unions xs)) &&
                           nullIntersections xs

checkUntyped :: Model Word -> ObjID -> Logger Bool
checkUntyped m ref = do
    let valid =
            case object ref m of
                Untyped _ -> True
                _ -> False
    unless valid
              (tell $ text $ show ref ++ " covers objects but is not an untyped")
    return valid

checkUntypeds :: Model Word -> Logger Bool
checkUntypeds m@(Model _ _ _ _ covMap) = do
    let objs = map fst (Map.toList covMap)
    allM (checkUntyped m) objs

checkUntypedCover :: Model Word -> (ObjID, [ObjID]) -> Logger Bool
checkUntypedCover m (id, objs) = do
    let valid = allM (objAt (const True)) objs m
    unless valid
                 (tell $ text $ show id ++ " covers a non-existant object")
    return valid

checkUntypedCovers :: Model Word -> Logger Bool
checkUntypedCovers m@(Model _ _ _ _ covMap) = do
    let covers = map (\(id, objs) -> (id, Set.toList objs)) (Map.toList covMap)
    allM (checkUntypedCover m) covers

checkCovers :: Model Word -> Logger Bool
checkCovers m = do
    let valid = nullIntersections $ allCovers m
    unless valid (tell $ text $
                               "At least two untypeds have intersecting covers")
    untypeds <- checkUntypeds m
    covers <- checkUntypedCovers m
    return $ valid && covers && untypeds

isIRQ :: KernelObject Word -> Bool
isIRQ (CNode _ 0) = True --check irqNode
isIRQ _ = False

validIRQ :: Model Word -> ObjID -> Bool
validIRQ m irq = isIRQ $ object irq m

checkIRQ :: Model Word -> (Word, ObjID) -> Logger Bool
checkIRQ m (slot, irq) = do
    let valid = validIRQ m irq
    unless valid (tell $ text $ "The object mapped by irq " ++ show slot ++ --FIXME:rewrite
                                     " in the irqNode is not a valid irq_slot")
    return valid

checkIRQNode :: Model Word -> Logger Bool
checkIRQNode m = allM (checkIRQ m) (Map.toList $ irqNode m)

checkModel :: Model Word -> Logger Bool
checkModel m = do
    objs <- checkObjs (arch m) m
    covers <- checkCovers m
    mappings <- checkMappings m
    irq <- checkIRQNode m
    tell $ text ""
    return $ objs && covers && mappings && irq
