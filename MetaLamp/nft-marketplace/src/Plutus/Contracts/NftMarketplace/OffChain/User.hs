{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

module Plutus.Contracts.NftMarketplace.OffChain.User where

import           Control.Lens                                  (_Left, (^.),
                                                                (^?))
import qualified Control.Lens                                  as Lens
import           Control.Monad                                 hiding (fmap)
import qualified Data.Aeson                                    as J
import           Data.Proxy                                    (Proxy (..))
import           Data.Text                                     (Text)
import qualified Data.Text                                     as T
import qualified Ext.Plutus.Contracts.Auction                  as Auction
import           Ext.Plutus.Ledger.Value                       (utxoValue)
import qualified GHC.Generics                                  as Haskell
import           Ledger
import qualified Ledger.Typed.Scripts                          as Scripts
import           Ledger.Typed.Tx
import qualified Ledger.Value                                  as V
import           Plutus.Abstract.ContractResponse              (ContractResponse,
                                                                withContractResponse)
import           Plutus.Contract
import           Plutus.Contract.StateMachine
import           Plutus.Contracts.Currency                     as Currency
import           Plutus.Contracts.NftMarketplace.OffChain.Info (fundsAt,
                                                                mapError',
                                                                marketplaceStore)
import qualified Plutus.Contracts.NftMarketplace.OnChain.Core  as Core
import qualified Plutus.Contracts.Services.Sale                as Sale
import qualified PlutusTx
import qualified PlutusTx.AssocMap                             as AssocMap
import           PlutusTx.Prelude                              hiding
                                                               (Semigroup (..))
import           Prelude                                       (Semigroup (..))
import qualified Prelude                                       as Haskell
import qualified Schema
import           Text.Printf                                   (printf)

getOwnPubKey :: Contract w s Text PubKeyHash
getOwnPubKey = pubKeyHash <$> ownPubKey

data CreateNftParams =
  CreateNftParams {
    cnpIpfsCid        :: ByteString,
    cnpNftName        :: ByteString,
    cnpNftDescription :: ByteString,
    cnpRevealIssuer   :: Bool
  }
    deriving stock    (Haskell.Eq, Haskell.Show, Haskell.Generic)
    deriving anyclass (J.ToJSON, J.FromJSON, Schema.ToSchema)

PlutusTx.unstableMakeIsData ''CreateNftParams
PlutusTx.makeLift ''CreateNftParams

-- | The user specifies which NFT to mint and add to marketplace store,
--   he gets it into his wallet and the corresponding store entry is created
createNft :: Core.Marketplace -> CreateNftParams -> Contract w s Text ()
createNft marketplace CreateNftParams {..} = do
    let ipfsCidHash = sha2_256 cnpIpfsCid
    nftStore <- marketplaceStore marketplace
    when (isJust $ AssocMap.lookup ipfsCidHash nftStore) $ throwError "Nft entry already exists"

    pkh <- getOwnPubKey
    let tokenName = V.TokenName cnpIpfsCid
    nft <-
           mapError (T.pack . Haskell.show @Currency.CurrencyError) $
           Currency.forgeContract pkh [(tokenName, 1)]

    let client = Core.marketplaceClient marketplace
    let nftEntry = Core.NFT
            { nftId          = Currency.currencySymbol nft
            , nftName        = cnpNftName
            , nftDescription = cnpNftDescription
            , nftIssuer      = if cnpRevealIssuer then Just pkh else Nothing
            , nftLot     = Nothing -- TODO validate that it's Nothing
            }
    void $ mapError' $ runStep client $ Core.CreateNftRedeemer ipfsCidHash nftEntry

    logInfo @Haskell.String $ printf "Created NFT %s with store entry %s" (Haskell.show nft) (Haskell.show nftEntry)
    pure ()

data OpenSaleParams =
  OpenSaleParams {
    ospIpfsCid   :: ByteString,
    ospSalePrice :: Sale.LovelacePrice
  }
    deriving stock    (Haskell.Eq, Haskell.Show, Haskell.Generic)
    deriving anyclass (J.ToJSON, J.FromJSON, Schema.ToSchema)

PlutusTx.unstableMakeIsData ''OpenSaleParams
PlutusTx.makeLift ''OpenSaleParams

-- | The user opens sale for his NFT
openSale :: Core.Marketplace -> OpenSaleParams -> Contract w s Text ()
openSale marketplace OpenSaleParams {..} = do
    let ipfsCidHash = sha2_256 ospIpfsCid
    nftStore <- marketplaceStore marketplace
    nftEntry <- maybe (throwError "NFT has not been created") pure $ AssocMap.lookup ipfsCidHash nftStore
    let tokenName = V.TokenName ospIpfsCid

    sale <- Sale.openSale
              Sale.OpenSaleParams {
                  ospSalePrice = ospSalePrice,
                  ospSaleValue = V.singleton (Core.nftId nftEntry) tokenName 1
              }

    let client = Core.marketplaceClient marketplace
    let lot = Core.Lot
                { lotLink          = Left $ Sale.toTuple sale
                , lotIpfsCid     = ospIpfsCid
                }
    void $ mapError' $ runStep client $ Core.PutLotRedeemer ipfsCidHash lot

    logInfo @Haskell.String $ printf "Created NFT sale %s" (Haskell.show lot)
    pure ()

data BuyNftParams =
  BuyNftParams {
    bnpIpfsCid   :: ByteString
  }
    deriving stock    (Haskell.Eq, Haskell.Show, Haskell.Generic)
    deriving anyclass (J.ToJSON, J.FromJSON, Schema.ToSchema)

PlutusTx.unstableMakeIsData ''BuyNftParams
PlutusTx.makeLift ''BuyNftParams

-- | The user buys specified NFT lot
buyNft :: Core.Marketplace -> BuyNftParams -> Contract w s Text ()
buyNft marketplace BuyNftParams {..} = do
    let ipfsCidHash = sha2_256 bnpIpfsCid
    nftStore <- marketplaceStore marketplace
    nftEntry <- maybe (throwError "NFT has not been created") pure $ AssocMap.lookup ipfsCidHash nftStore
    nftSale <- maybe (throwError "NFT has not been put on sale") pure $
                  nftEntry ^. Core._nftLot ^? traverse . Core._lotLink . _Left

    _ <- Sale.buyLot $ Sale.fromTuple nftSale

    let client = Core.marketplaceClient marketplace
    void $ mapError' $ runStep client $ Core.RemoveLotRedeemer ipfsCidHash

    logInfo @Haskell.String $ printf "Bought NFT from sale %s" (Haskell.show nftSale)
    pure ()

data CloseSaleParams =
  CloseSaleParams {
    cspIpfsCid   :: ByteString
  }
    deriving stock    (Haskell.Eq, Haskell.Show, Haskell.Generic)
    deriving anyclass (J.ToJSON, J.FromJSON, Schema.ToSchema)

PlutusTx.unstableMakeIsData ''CloseSaleParams
PlutusTx.makeLift ''CloseSaleParams

-- | The user closes NFT sale and receives his token back
closeSale :: Core.Marketplace -> CloseSaleParams -> Contract w s Text ()
closeSale marketplace CloseSaleParams {..} = do
    let ipfsCidHash = sha2_256 cspIpfsCid
    nftStore <- marketplaceStore marketplace
    nftEntry <- maybe (throwError "NFT has not been created") pure $ AssocMap.lookup ipfsCidHash nftStore
    nftSale <- maybe (throwError "NFT has not been put on sale") pure $
                  nftEntry ^. Core._nftLot ^? traverse . Core._lotLink . _Left

    _ <- Sale.redeemLot $ Sale.fromTuple nftSale

    let client = Core.marketplaceClient marketplace
    void $ mapError' $ runStep client $ Core.RemoveLotRedeemer ipfsCidHash

    logInfo @Haskell.String $ printf "Closed NFT sale %s" (Haskell.show nftSale)
    pure ()

data HoldAnAuctionParams =
  HoldAnAuctionParams {
    haapIpfsCid  :: ByteString,
    haapDuration :: Slot
  }
    deriving stock    (Haskell.Eq, Haskell.Show, Haskell.Generic)
    deriving anyclass (J.ToJSON, J.FromJSON, Schema.ToSchema)

PlutusTx.unstableMakeIsData ''HoldAnAuctionParams
PlutusTx.makeLift ''HoldAnAuctionParams

-- | The user
holdAnAuction :: Core.Marketplace -> HoldAnAuctionParams -> Contract w s Text ()
holdAnAuction marketplace HoldAnAuctionParams {..} = do
    let ipfsCidHash = sha2_256 haapIpfsCid
    nftStore <- marketplaceStore marketplace
    nftEntry <- maybe (throwError "NFT has not been created") pure $ AssocMap.lookup ipfsCidHash nftStore
    let tokenName = V.TokenName haapIpfsCid
    let nftValue = V.singleton (Core.nftId nftEntry) tokenName 1

    currSlot <- currentSlot
    let endTime = currSlot + haapDuration
    (auctionToken, auctionParams) <- mapError (T.pack . Haskell.show) $ Auction.startAuction nftValue endTime

    let client = Core.marketplaceClient marketplace
    let lot = Core.Lot
                { lotLink          = Right $ Auction.toTuple auctionToken auctionParams
                , lotIpfsCid     = haapIpfsCid
                }
    void $ mapError' $ runStep client $ Core.PutLotRedeemer ipfsCidHash lot

    _ <- mapError (T.pack . Haskell.show) $ Auction.payoutAuction auctionToken auctionParams

    void $ mapError' $ runStep client $ Core.RemoveLotRedeemer ipfsCidHash

    logInfo @Haskell.String $ printf "Conducted an auction for NFT lot %s" (Haskell.show lot)
    pure ()

balanceAt :: PubKeyHash -> AssetClass -> Contract w s Text Integer
balanceAt pkh asset = flip V.assetClassValueOf asset <$> fundsAt pkh

ownPubKeyBalance :: Contract w s Text Value
ownPubKeyBalance = getOwnPubKey >>= fundsAt

type MarketplaceUserSchema =
    Endpoint "createNft" CreateNftParams
    .\/ Endpoint "openSale" OpenSaleParams
    .\/ Endpoint "buyNft" BuyNftParams
    .\/ Endpoint "closeSale" CloseSaleParams
    .\/ Endpoint "holdAnAuction" HoldAnAuctionParams
    .\/ Endpoint "ownPubKey" ()
    .\/ Endpoint "ownPubKeyBalance" ()

data UserContractState =
    NftCreated
    | OpenedSale
    | NftBought
    | ClosedSale
    | AuctionComplete
    | GetPubKey PubKeyHash
    | GetPubKeyBalance Value
    deriving stock (Haskell.Eq, Haskell.Show, Haskell.Generic)
    deriving anyclass (J.ToJSON, J.FromJSON)

Lens.makeClassyPrisms ''UserContractState

userEndpoints :: Core.Marketplace -> Contract (ContractResponse Text UserContractState) MarketplaceUserSchema Void ()
userEndpoints marketplace = forever $
    withContractResponse (Proxy @"createNft") (const NftCreated) (createNft marketplace)
    `select` withContractResponse (Proxy @"openSale") (const OpenedSale) (openSale marketplace)
    `select` withContractResponse (Proxy @"buyNft") (const NftBought) (buyNft marketplace)
    `select` withContractResponse (Proxy @"closeSale") (const ClosedSale) (closeSale marketplace)
    `select` withContractResponse (Proxy @"holdAnAuction") (const AuctionComplete) (holdAnAuction marketplace)
    `select` withContractResponse (Proxy @"ownPubKey") GetPubKey (const getOwnPubKey)
    `select` withContractResponse (Proxy @"ownPubKeyBalance") GetPubKeyBalance (const ownPubKeyBalance)
