{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-|
Module      : Hypercube.Game
Description : The main game loops and start function
Copyright   : (c) Jaro Reinders, 2017
License     : GPL-3
Maintainer  : noughtmare@openmailbox.org

This module contains the @start@ function, the @mainLoop@ and the @draw@ function.

TODO: find a better place for the @draw@ function.
-}

module Hypercube.Game where

import Hypercube.Chunk
import Hypercube.Types
import Hypercube.Config
import Hypercube.Util
import Hypercube.Shaders
import Hypercube.Input

import qualified Debug.Trace as D

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.State
import Control.Lens
import Control.Concurrent
import Control.Exception
import Data.Maybe
import qualified Graphics.Rendering.OpenGL as GL
import qualified Graphics.GLUtil as U
import Graphics.UI.GLFW as GLFW
import Linear
import qualified Data.Vector.Storable as VS
import qualified Data.Map.Strict as M
import Control.Concurrent.STM.TChan
import Control.Monad.STM
import Control.Applicative
import Data.Int (Int8)
import System.Mem (performMinorGC)
import Data.List
import Data.IORef
import Foreign.Storable (sizeOf)
import Foreign.C.Types (CPtrdiff (CPtrdiff))
import Data.Function
import Data.MemoTrie

data Timeout = Timeout
  deriving (Show)

instance Exception Timeout

timeout :: Int -> IO () -> IO ()
timeout microseconds action = do
  currentThreadId <- myThreadId
  forkIO $ threadDelay microseconds >> throwTo currentThreadId Timeout
  handle (\Timeout -> return ()) action

start :: IO ()
start = withWindow 1280 720 "Hypercube" $ \win -> do
  -- Disable the cursor
  GLFW.setCursorInputMode win GLFW.CursorInputMode'Disabled

  todo <- newIORef []
  chan <- newTChanIO
  startChunkManager todo chan


  -- Generate a new game world
  game <- Game (Camera (V3 8 15 8) 0 0 5 0.05)
           <$> (realToFrac . fromJust <$> GLFW.getTime)
           <*> (fmap realToFrac . uncurry V2 <$> GLFW.getCursorPos win)
           <*> pure M.empty

  void $ flip runStateT game $ do
    -- vsync
    liftIO $ GLFW.swapInterval 1

    p <- liftIO shaders

    -- Get the shader uniforms
    [modelLoc,viewLoc,projLoc] <- liftIO $
      mapM (GL.get . GL.uniformLocation p) ["model","view","projection"]

    liftIO $ do
      -- Set shader
      GL.currentProgram GL.$= Just p

      do -- Load texture & generate mipmaps
        (Right texture) <- U.readTexture "blocks.png"
        GL.textureBinding GL.Texture2D GL.$= Just texture
        GL.textureFilter  GL.Texture2D GL.$= ((GL.Nearest,Nothing),GL.Nearest)

        GL.generateMipmap' GL.Texture2D

      -- Set clear color
      GL.clearColor GL.$= GL.Color4 0.2 0.3 0.3 1

      GLFW.setKeyCallback win (Just keyCallback)

      GL.cullFace  GL.$= Just GL.Back
      GL.depthFunc GL.$= Just GL.Less

    mainLoop win todo chan viewLoc projLoc modelLoc

unitDodecahedron :: [(Int, V3 Float)]
unitDodecahedron = zip [1..] $ [[x,y,z] | x <- [1,-1], y <- [1,-1], z <- [1,-1]]
                            ++ ([[0,x * phi, y / phi] | x <- [1,-1], y <- [1,-1]]
                           >>= cyclicPermutations)
                           >>= \[x,y,z] -> return (normalize (V3 x y z))

unitIcosahedron :: [(Int,V3 Float)]
unitIcosahedron = zip [1..] $ [[0, x, y * phi] | x <- [1,-1], y <- [1,-1]] 
                          >>= cyclicPermutations 
                          >>= \[x,y,z] -> return (normalize (V3 x y z))

-- golden ratio
phi :: Float
phi = (1 + sqrt 5) / 2

cyclicPermutations :: [a] -> [[a]]
cyclicPermutations xs = let l = length xs in take l $ map (take l) $ tails (cycle xs)

visibleChunks :: Int -> Int -> V3 Float -> [V3 Int]
visibleChunks height width gaze = memo3 f height width (fst (minimumBy (compare `on` distance gaze . snd) unitDodecahedron))
  where
   f :: Int -> Int -> Int -> [V3 Int]
   f height width n = 
     let gaze = fromJust (lookup n unitDodecahedron)
         fov :: Float
         fov = pi / 4 + 0.47
         view :: M44 Float
         view = lookAt (- (fromIntegral chunkSize * sqrt 2) / (2 * atan (fov / 2)) *^ gaze) 0 (V3 0 1 0)
         proj :: M44 Float
         proj = perspective fov (fromIntegral width / fromIntegral height) 0.1 1000
     in sortOn (distance 0 . fmap fromIntegral) $ do
       let r = renderDistance
       v <- liftA3 V3 [-r..r] [-r..r] [-r..r]
       let projected = proj !*! view !* model
           model = (identity & translation .~ (fromIntegral <$> (chunkSize *^ v)))
             !* (1 & _xyz .~ fromIntegral chunkSize / 2)
           normalized = liftA2 (^/) id (^. _w) $ projected
       guard $ all ((<= 1) . abs) $ normalized ^. _xyz
       return v


draw :: Int -> Int -> V3 Float -> M44 Float -> GL.UniformLocation -> IORef [V3 Int] ->  StateT Game IO ()
draw height width gaze vp modelLoc todo = do
  let
    render :: V3 Int -> StateT Game IO [V3 Int]
    render pos = do 
      m <- use world
      case M.lookup pos m of
        Nothing -> return [pos]
        Just c -> do
          liftIO (execStateT (renderChunk pos modelLoc) c) -- >>= (world %=) . M.insert v
          return []

  playerPos <- fmap ((`div` chunkSize) . floor) <$> use (cam . camPos)
  let r = renderDistance
  liftIO . atomicWriteIORef todo . concat =<< mapM render 
    (map (+ playerPos) (visibleChunks height width gaze))

mainLoop :: GLFW.Window -> IORef [V3 Int] -> TChan (V3 Int, Chunk, VS.Vector (V4 Int8)) 
  -> GL.UniformLocation -> GL.UniformLocation -> GL.UniformLocation -> StateT Game IO ()
mainLoop win todo chan viewLoc projLoc modelLoc = do
  shouldClose <- liftIO $ GLFW.windowShouldClose win
  unless shouldClose $ do

    liftIO GLFW.pollEvents

    deltaTime <- do
      currentFrame <- realToFrac . fromJust <$> liftIO GLFW.getTime
      deltaTime <- (currentFrame -) <$> use lastFrame
      lastFrame .= currentFrame
      return deltaTime

    liftIO $ print $ 1/deltaTime

    keyboard win deltaTime
    mouse win deltaTime

    -- Handle Window resize
    (width, height) <- liftIO $ GLFW.getFramebufferSize win
    liftIO $ GL.viewport GL.$=
      (GL.Position 0 0, GL.Size (fromIntegral width) (fromIntegral height))

    -- Clear buffers
    liftIO $ GL.clear [GL.ColorBuffer, GL.DepthBuffer]

    -- Change view matrix
    curCamPos  <- use (cam . camPos)
    curGaze <- use (cam . gaze)

    let view = lookAt curCamPos (curCamPos + curGaze) (V3 0 1 0)
    viewMat <- liftIO $ toGLmatrix view
    GL.uniform viewLoc GL.$= viewMat

    -- Change projection matrix
    let proj = perspective (pi / 4) (fromIntegral width / fromIntegral height) 0.1 1000
    projMat <- liftIO $ toGLmatrix proj
    GL.uniform projLoc GL.$= projMat

    do
      let
        loadVbos = do
          -- TODO: better timeout estimate (calculate time left until next frame)
          t <- liftIO $ (+ 0.001) . fromJust <$> GLFW.getTime
          liftIO (atomically (tryReadTChan chan)) >>= maybe (return ()) (\(pos,Chunk blk _ _ _,v) -> do
            m <- use world
            if pos `M.member` m then
              loadVbos
            else do
              let len = VS.length v
              vbo <- GL.genObjectName
              liftIO $ when (len > 0) $ do
                GL.bindBuffer GL.ArrayBuffer GL.$= Just vbo
                VS.unsafeWith v $ \ptr ->
                  GL.bufferData GL.ArrayBuffer GL.$= 
                    (CPtrdiff (fromIntegral (sizeOf (undefined :: V4 Int8) * len)), ptr, GL.StaticDraw)
                GL.bindBuffer GL.ArrayBuffer GL.$= Nothing
              world %= M.insert pos (Chunk blk vbo len False)
              t' <- liftIO $ fromJust <$> GLFW.getTime
              when (t' < t) loadVbos)
      loadVbos

    draw height width curGaze (proj !*! view) modelLoc todo

    liftIO $ GLFW.swapBuffers win

    --liftIO $ performMinorGC

    mainLoop win todo chan viewLoc projLoc modelLoc

