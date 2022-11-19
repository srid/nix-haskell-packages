{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE UndecidableInstances #-}

module NHI.Route where

import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Sequence (chunksOf)
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Ema
import Ema.Route.Generic
import Ema.Route.Lib.Extra.StaticRoute qualified as SR
import Ema.Route.Lib.Extra.StringRoute (StringRoute (StringRoute))
import Ema.Route.Prism (Prism_)
import Generics.SOP qualified as SOP
import NHI.PaginatedRoute (Page, PaginatedRoute, getPage)
import NHI.Types (NixData, Pkg (..))
import Optics.Core (preview, prism', review)

data Model = Model
  { modelBaseUrl :: Text
  , modelStatic :: SR.Model
  , modelData :: NixData
  }
  deriving stock (Eq, Show, Generic)

type PaginatedListingRoute = PaginatedRoute (Text, NonEmpty Pkg)

data ListingRoute
  = ListingRoute_MultiVersion PaginatedListingRoute
  | ListingRoute_All PaginatedListingRoute
  | ListingRoute_Broken PaginatedListingRoute
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo)
  deriving
    (HasSubRoutes, IsRoute)
    via ( GenericRoute
            ListingRoute
            '[ WithModel [(Text, NonEmpty Pkg)]
             , WithSubRoutes
                '[ PaginatedListingRoute
                 , FolderRoute "all" PaginatedListingRoute
                 , FolderRoute "broken" PaginatedListingRoute
                 ]
             ]
        )

listingRoutePage :: ListingRoute -> Page
listingRoutePage = \case
  ListingRoute_MultiVersion r -> getPage r
  ListingRoute_All r -> getPage r
  ListingRoute_Broken r -> getPage r

-- | Like (==) but ignores the pagination
listingEq :: ListingRoute -> ListingRoute -> Bool
listingEq (ListingRoute_All _) (ListingRoute_All _) = True
listingEq (ListingRoute_Broken _) (ListingRoute_Broken _) = True
listingEq x y = x == y

instance HasSubModels ListingRoute where
  subModels m =
    SOP.I (pages $ filter (\(_, xs) -> length xs > 1) m)
      SOP.:* SOP.I (pages m)
      SOP.:* SOP.I (pages $ filter (\(_, v) -> any (\Pkg {..} -> pname == name && broken) v) m)
      SOP.:* SOP.Nil
    where
      pages :: [a] -> [[a]]
      pages xs = fmap toList . toList $ chunksOf pageSize (Seq.fromList xs)
        where
          pageSize :: Int
          pageSize = 500

data GhcRoute
  = GhcRoute_Index ListingRoute
  | GhcRoute_Package Text
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo)
  deriving
    (HasSubRoutes, IsRoute)
    via ( GenericRoute
            GhcRoute
            '[ WithModel (Map Text (NonEmpty Pkg))
             , WithSubRoutes
                '[ ListingRoute
                 , FolderRoute "p" (StringRoute (NonEmpty Pkg) Text)
                 ]
             ]
        )

instance HasSubModels GhcRoute where
  subModels m =
    SOP.I (Map.toList m) SOP.:* SOP.I m SOP.:* SOP.Nil

data HtmlRoute
  = HtmlRoute_GHC (Text, GhcRoute)
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo)
  deriving
    (HasSubRoutes, HasSubModels, IsRoute)
    via ( GenericRoute
            HtmlRoute
            '[ WithModel NixData
             , WithSubRoutes
                '[ MapRoute Text GhcRoute
                 ]
             ]
        )

type StaticRoute = SR.StaticRoute "static"

data Route
  = Route_Html HtmlRoute
  | Route_Static StaticRoute
  deriving stock (Eq, Show, Ord, Generic)
  deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo)
  deriving
    (HasSubRoutes, HasSubModels, IsRoute)
    via ( GenericRoute
            Route
            '[ WithModel Model
             , WithSubRoutes
                '[ HtmlRoute
                 , StaticRoute
                 ]
             ]
        )

-- TODO: upstream; https://github.com/EmaApps/ema/issues/144

{- | Like `FolderRoute` but using dynamic folder name, looked up on a `Map`.

  Empty folder name (map keys) are supported. They would translate in effect to the looked up route (no folder created).
-}
newtype MapRoute k r = MapRoute (k, r)
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo)

instance (IsRoute r, IsString k, ToString k, Ord k, Show r) => IsRoute (MapRoute k r) where
  type RouteModel (MapRoute k r) = Map k (RouteModel r)
  routePrism :: (IsRoute r, IsString k) => RouteModel (MapRoute k r) -> Prism_ FilePath (MapRoute k r)
  routePrism rs =
    toPrism_ $
      prism'
        ( \(MapRoute (k, r)) ->
            let m = fromJust $ Map.lookup k rs -- HACK: fromJust
                prefix = if toString k == "" then "" else toString k <> "/"
             in prefix <> review (fromPrism_ $ routePrism @r m) r
        )
        ( \fp -> do
            let candidates =
                  case breakPath fp of
                    (a, Nothing) -> [("", a)]
                    (a, Just b) -> [(a, b), ("", fp)]
            (m, k, rest) <-
              asum $
                candidates <&> \(base, rest) ->
                  let k = fromString base
                   in (,k,rest) <$> Map.lookup k rs
            r <- preview (fromPrism_ $ routePrism @r m) (toString rest)
            pure $ MapRoute (k, r)
        )
    where
      -- Breaks a path once on the first slash.
      breakPath (s :: String) =
        case T.breakOn "/" (toText s) of
          (p, "") -> (toString p, Nothing)
          (p, toString -> '/' : rest) -> (toString p, Just rest)
          _ -> error "T.breakOn: impossible"

  routeUniverse rs = concatMap (\(a, m) -> MapRoute . (a,) <$> routeUniverse m) $ Map.toList rs
