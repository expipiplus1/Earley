-- | Context-free grammars.
{-# LANGUAGE CPP, GADTs, RankNTypes #-}
module Text.Earley.Grammar
  ( Prod(..)
  , terminal
  , (<?>)
  , constraint
  , constraintM
  , alts
  , Grammar(..)
  , rule
  , runGrammar
  ) where
import Control.Applicative
import Control.Monad
import Control.Monad.Fix
import Data.String (IsString(..))
#if !MIN_VERSION_base(4,8,0)
import Data.Monoid
#endif
import Data.Semigroup

infixr 0 <?>

-- | A production.
--
-- The type parameters are:
--
-- @a@: The return type of the production.
--
-- @t@ for terminal: The type of the terminals that the production operates
-- on.
--
-- @e@ for expected: The type of names, used for example to report expected
-- tokens.
--
-- @r@ for rule: The type of a non-terminal. This plays a role similar to the
-- @s@ in the type @ST s a@.  Since the 'parser' function expects the @r@ to be
-- universally quantified, there is not much to do with this parameter other
-- than leaving it universally quantified.
--
-- As an example, @'Prod' r 'String' 'Char' 'Int'@ is the type of a production that
-- returns an 'Int', operates on (lists of) characters and reports 'String'
-- names.
--
-- Most of the functionality of 'Prod's is obtained through its instances, e.g.
-- 'Functor', 'Applicative', and 'Alternative'.
data Prod r m e t a where
  -- Applicative.
  Terminal    :: !(t -> Maybe a) -> !(Prod r m e t (a -> b)) -> Prod r m e t b
  NonTerminal :: !(r e t a) -> !(Prod r m e t (a -> b)) -> Prod r m e t b
  Pure        :: a -> Prod r m e t a
  -- Monoid/Alternative. We have to special-case 'many' (though it can be done
  -- with rules) to be able to satisfy the Alternative interface.
  Alts        :: ![Prod r m e t a] -> !(Prod r m e t (a -> b)) -> Prod r m e t b
  Many        :: !(Prod r m e t a) -> !(Prod r m e t ([a] -> b)) -> Prod r m e t b
  -- Error reporting.
  Named       :: !(Prod r m e t a) -> e -> Prod r m e t a
  -- Non-context-free extension: conditioning on the parsed output.
  Constraint  :: !(Prod r m e t a) -> (a -> m Bool) -> Prod r m e t a

-- | Match a token for which the given predicate returns @Just a@,
-- and return the @a@.
terminal :: (t -> Maybe a) -> Prod r m e t a
terminal p = Terminal p $ Pure id

-- | A named production (used for reporting expected things).
(<?>) :: Prod r m e t a -> e -> Prod r m e t a
(<?>) = Named

-- | A parser that filters results, post-parsing
constraint :: Applicative m => (a -> Bool) -> Prod r m e t a -> Prod r m e t a
constraint p = flip Constraint (pure . p)

constraintM :: (a -> m Bool) -> Prod r m e t a -> Prod r m e t a
constraintM = flip Constraint

-- | Lifted instance: @(<>) = 'liftA2' ('<>')@
instance Semigroup a => Semigroup (Prod r m e t a) where
  (<>) = liftA2 (Data.Semigroup.<>)

-- | Lifted instance: @mempty = 'pure' 'mempty'@
instance Monoid a => Monoid (Prod r m e t a) where
  mempty  = pure mempty
  mappend = liftA2 mappend

instance Functor (Prod r m e t) where
  {-# INLINE fmap #-}
  fmap f (Terminal b p)    = Terminal b $ fmap (f .) p
  fmap f (NonTerminal r p) = NonTerminal r $ fmap (f .) p
  fmap f (Pure x)          = Pure $ f x
  fmap f (Alts as p)       = Alts as $ fmap (f .) p
  fmap f (Many p q)        = Many p $ fmap (f .) q
  fmap f (Named p n)       = Named (fmap f p) n

-- | Smart constructor for alternatives.
alts :: [Prod r m e t a] -> Prod r m e t (a -> b) -> Prod r m e t b
alts as p = case as >>= go of
  []  -> empty
  [a] -> a <**> p
  as' -> Alts as' p
  where
    go (Alts [] _)         = []
    go (Alts as' (Pure f)) = fmap f <$> as'
    go (Named p' n)        = map (<?> n) $ go p'
    go a                   = [a]

instance Applicative (Prod r m e t) where
  pure = Pure
  {-# INLINE (<*>) #-}
  Terminal b p    <*> q = Terminal b $ flip <$> p <*> q
  NonTerminal r p <*> q = NonTerminal r $ flip <$> p <*> q
  Pure f          <*> q = fmap f q
  Alts as p       <*> q = alts as $ flip <$> p <*> q
  Many a p        <*> q = Many a $ flip <$> p <*> q
  Named p n       <*> q = Named (p <*> q) n

instance Alternative (Prod r m e t) where
  empty = Alts [] $ pure id
  Named p m <|> q         = Named (p <|> q) m
  p         <|> Named q n = Named (p <|> q) n
  p         <|> q         = alts [p, q] $ pure id
  many (Alts [] _) = pure []
  many p           = Many p $ Pure id
  some p           = (:) <$> p <*> many p

-- | String literals can be interpreted as 'Terminal's
-- that match that string.
--
-- >>> :set -XOverloadedStrings
-- >>> import Data.Text (Text)
-- >>> let determiner = "the" <|> "a" <|> "an" :: Prod r e Text Text
--
instance (IsString t, Eq t, a ~ t) => IsString (Prod r m e t a) where
  fromString s = Terminal f $ Pure id
    where
      fs = fromString s
      f t | t == fs = Just fs
      f _ = Nothing
  {-# INLINE fromString #-}

-- | A context-free grammar.
--
-- The type parameters are:
--
-- @a@: The return type of the grammar (often a 'Prod').
--
-- @r@ for rule: The type of a non-terminal. This plays a role similar to the
-- @s@ in the type @ST s a@.  Since the 'parser' function expects the @r@ to be
-- universally quantified, there is not much to do with this parameter other
-- than leaving it universally quantified.
--
-- Most of the functionality of 'Grammar's is obtained through its instances,
-- e.g.  'Monad' and 'MonadFix'. Note that GHC has syntactic sugar for
-- 'MonadFix': use @{-\# LANGUAGE RecursiveDo \#-}@ and @mdo@ instead of
-- @do@.
data Grammar r m a where
  RuleBind :: Prod r m e t a -> (Prod r m e t a -> Grammar r m b) -> Grammar r m b
  FixBind  :: (a -> Grammar r m a) -> (a -> Grammar r m b) -> Grammar r m b
  Return   :: a -> Grammar r m a

instance Functor (Grammar r m) where
  fmap f (RuleBind ps h) = RuleBind ps (fmap f . h)
  fmap f (FixBind g h)   = FixBind g (fmap f . h)
  fmap f (Return x)      = Return $ f x

instance Applicative (Grammar r m) where
  pure  = return
  (<*>) = ap

instance Monad (Grammar r m) where
  return = Return
  RuleBind ps f >>= k = RuleBind ps (f >=> k)
  FixBind f g   >>= k = FixBind f (g >=> k)
  Return x      >>= k = k x

instance MonadFix (Grammar r m) where
  mfix f = FixBind f return

-- | Create a new non-terminal by giving its production.
rule :: Prod r m e t a -> Grammar r m (Prod r m e t a)
rule p = RuleBind p return

-- | Run a grammar, given an action to perform on productions to be turned into
-- non-terminals.
runGrammar :: MonadFix m
           => (forall e t a. Prod r n e t a -> m (Prod r n e t a))
           -> Grammar r n b -> m b
runGrammar r grammar = case grammar of
  RuleBind p k -> do
    nt <- r p
    runGrammar r $ k nt
  Return a -> return a
  FixBind f k -> do
    a <- mfix $ runGrammar r <$> f
    runGrammar r $ k a
