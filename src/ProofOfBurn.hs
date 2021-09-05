{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}

{-# OPTIONS_GHC -fno-warn-unused-imports #-}
module ProofOfBurn where 
-- | This is a burner contract,
--
-- And add function implementations (and rename them to
-- something suitable) for the endpoints:
--   * lock - which locks the value to be redeemed by an addressee;
--   * redeem - which redeems the locked value;
--   * burn - which burns the value instead of locking it.
--
--  In order to check that value was indeed burned, one needs to run a `burned` script with the same commitment value.

import           Control.Monad             (void)
import           Data.Bits                 (xor)
import           Data.Char                 (ord, chr)
import           Data.Sequences            (snoc, unsnoc)
import qualified Data.Map                  as Map
import qualified Data.List.NonEmpty        as NonEmpty(toList)
import           Plutus.Contract
import qualified PlutusTx         as PlutusTx
import           PlutusTx.Prelude hiding (Applicative (..))
import           Ledger                    (Address, scriptAddress)
import qualified Ledger.Constraints        as Constraints
import qualified Ledger.Typed.Scripts      as Scripts
import           Ledger.Typed.Scripts.Validators(ValidatorType)
import           Ledger.Value              (Value)
import           Plutus.V1.Ledger.Crypto
import           Plutus.V1.Ledger.Contexts
import           Plutus.V1.Ledger.Tx (Tx, TxOutRef, TxOutTx(..), txData, txOutDatum)
import           Playground.Contract

-- | Utxo datum holds either:
--     * the hash of the address that can redeem the value, if it was locked;
--     * the hash with the last bit flipped, if it was burned.
newtype MyDatum = MyDatum { fromMyDatum :: ByteString } deriving newtype PlutusTx.IsData
PlutusTx.makeLift ''MyDatum

-- | Redeemer holds no data, since the address is taken from the context.
newtype MyRedeemer = MyRedeemer { _nothing :: () } deriving newtype PlutusTx.IsData
PlutusTx.makeLift ''MyRedeemer

-- | Spending validator checks that hash of the redeeming address is the same as the Utxo datum.
validateSpend :: ValidatorType Burner
validateSpend (MyDatum addrHash) _myRedeemerValue ScriptContext { scriptContextTxInfo = TxInfo { txInfoSignatories = [addr] } } =
   addrHash == sha3_256 (getPubKeyHash addr)
validateSpend _ _  _ = traceError "Expecting exactly one signatory."

-- | The address of the contract (the hash of its validator script).
contractAddress :: Address
contractAddress = Ledger.scriptAddress (Scripts.validatorScript burnerValidator)

data Burner
instance Scripts.ValidatorTypes Burner where
    type instance RedeemerType  Burner = MyRedeemer
    type instance DatumType     Burner = MyDatum

{-
burnerInstance :: Scripts.ScriptInstance Burner
burnerInstance = Scripts.validator @Burner
    $$(PlutusTx.compile [|| validateSpend ||])
    $$(PlutusTx.compile [|| wrap ||]) where
        wrap = Scripts.wrapValidator @MyDatum @MyRedeemer
 -}

-- | The script instance is the compiled validator (ready to go onto the chain)
burnerValidator :: Scripts.TypedValidator Burner
burnerValidator = Scripts.mkTypedValidator @Burner
    $$(PlutusTx.compile [|| validateSpend ||])
    $$(PlutusTx.compile [|| wrap          ||])
  where
    wrap = Scripts.wrapValidator @MyDatum @MyRedeemer

-- | The schema of the contract, with two endpoints.
type Schema = Endpoint "lock"   (PubKeyHash, Value) -- lock the value
          .\/ Endpoint "burn"   (ByteString, Value) -- burn the value
          .\/ Endpoint "redeem" ()                  -- redeem the locked value

contract :: AsContractError e => Contract w Schema e ()
contract = lock `select` burn `select` redeem

-- | The "lock" contract endpoint.
--
--   Lock the value to the given addressee.
lock :: AsContractError e => Contract w Schema e ()
lock = do
    (addr, lockedFunds) <- endpoint @"lock"
    let hash = sha3_256 $ getPubKeyHash addr
    let tx = Constraints.mustPayToTheScript (MyDatum hash) lockedFunds
    void $ submitTxConstraints burnerValidator tx

-- | The "burn" contract endpoint.
--
--   Burn the value with the given commitment.
burn :: AsContractError e => Contract w Schema e ()
burn = do
    (aCommitment, burnedFunds) <- endpoint @"burn"
    let hash = flipCommitment $ sha3_256 $ aCommitment
    let tx = Constraints.mustPayToTheScript (MyDatum hash) burnedFunds
    void $ submitTxConstraints burnerValidator tx

-- | Flip lowest bit in the commitment
--
--   Requires non-empty bytestring as argument
flipCommitment :: ByteString -> ByteString
flipCommitment bs = do
  case unsnoc bs of
    Nothing             -> traceError "Hash was empty" -- input was empty
    Just (seq, lastElt) -> snoc seq
                         $ lastElt `xor` 1

-- | The "redeem" contract endpoint.
--
--   Can redeem the value, if it was published, not burned.
redeem :: AsContractError e => Contract w Schema e ()
redeem = do
    endpoint @"redeem"
    unspentOutputs <- utxoAt contractAddress
    let redeemer = MyRedeemer ()
        tx       = collectFromScript unspentOutputs redeemer
    void $ submitTxConstraintsSpending burnerValidator unspentOutputs tx


-- | The "burned" confirmation endpoint
--
--   Confirms that the value was burned with the given commitment.
{-
burned :: AsContractError e => ByteString -> Contract w Schema e Value
burned aCommitment = do
    unspentOutputs <- utxoAt contractAddress
    return $ totalValue (withCommitment `Map.filter` unspentOutputs)
    {-let redeemer = MyRedeemer
        tx       = collectFromScript unspentOutputs redeemer
    void $ submitTxConstraintsSpending burnerInstance unspentOutputs tx -}
  where
    totalValue         = mconcat . fmap (txOutValue . snd) . Map.toList
    withCommitment    :: TxOutTx -> Bool
    withCommitment txo = (fmap fromMyDatum $ PlutusTx.fromData $ txOutDatum $ txData $ txOutTxTx txo) == Just hash
    hash               = flipCommitment $ sha3_256 aCommitment
 -}

endpoints :: AsContractError e => Contract w Schema e ()
endpoints = contract

mkSchemaDefinitions ''Schema

$(mkKnownCurrencies [])
