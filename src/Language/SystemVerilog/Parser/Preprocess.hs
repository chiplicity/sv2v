{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - SystemVerilog Preprocessor
 -
 - This preprocessor handles all preprocessor directives and produces an output
 - stream that is tagged with the effective source position of resulting
 - characters.
 -}
module Language.SystemVerilog.Parser.Preprocess
    ( preprocess
    , Env
    ) where

import Control.Monad.Except
import Control.Monad.State
import Data.Char (ord)
import Data.List (span, elemIndex, dropWhileEnd, splitAt, tails, isPrefixOf, findIndex)
import Data.Maybe (isJust, fromJust)
import System.Directory (findFile)
import System.FilePath (dropFileName)
import qualified Data.Map.Strict as Map

import Language.SystemVerilog.Parser.Tokens (Position(..))

type Env = Map.Map String (String, [(String, Maybe String)])

type PPS = StateT PP (ExceptT String IO)

data PP = PP
    { ppInput        :: String -- current input string
    , ppOutput       :: [(Char, Position)] -- preprocessor output (in reverse)
    , ppPosition     :: Position -- current file position
    , ppFilePath     :: FilePath -- currently active filename
    , ppEnv          :: Env -- active macro definitions
    , ppCondStack    :: [Cond] -- if-else cascade state
    , ppIncludePaths :: [FilePath] -- folders to search for includes
    } deriving (Eq, Show)

-- keeps track of the state of an if-else cascade level
data Cond
    = CurrentlyTrue
    | PreviouslyTrue
    | NeverTrue
    deriving (Eq, Show)

-- preprocessor entrypoint
preprocess :: [String] -> Env -> FilePath -> IO (Either String ([(Char, Position)], Env))
preprocess includePaths env path = do
    contents <-
        if path == "-"
            then getContents
            else loadFile path
    let initialState = PP contents [] (Position path 1 1) path env [] includePaths
    result <- runExceptT $ execStateT preprocessInput initialState
    return $ case result of
        Left msg -> Left msg
        Right finalState ->
            if not $ null $ ppCondStack finalState then
                Left $ path ++ ": unfinished conditional directives: " ++
                    (show $ length $ ppCondStack finalState)
            else
                Right (output, env')
                where
                    output = reverse $ ppOutput finalState
                    env' = ppEnv finalState

-- read in the given file
loadFile :: FilePath -> IO String
loadFile path = do
    contents <- readFile path
    return $ normalize contents
    where
        -- removes carriage returns before newlines
        normalize :: String -> String
        normalize ('\r' : '\n' : rest) = '\n' : (normalize rest)
        normalize (ch : chs) = ch : (normalize chs)
        normalize [] = []

-- find the given file for inclusion
includeSearch :: FilePath -> PPS FilePath
includeSearch file = do
    base <- getFilePath
    includePaths <- gets ppIncludePaths
    let directories = dropFileName base : includePaths
    result <- liftIO $ findFile directories file
    case result of
        Just path -> return path
        Nothing -> lexicalError $ "Could not find file " ++ show file ++
                        ", included from " ++ show base

lexicalError :: String -> PPS a
lexicalError msg = do
    pos <- getPosition
    lift $ throwError $ show pos ++ ": Lexical error: " ++ msg

-- input accessors
setInput :: String -> PPS ()
setInput x = modify $ \s -> s { ppInput = x }
getInput :: PPS String
getInput = gets ppInput
-- output accessors
setOutput :: [(Char, Position)] -> PPS ()
setOutput x = modify $ \s -> s { ppOutput = x }
getOutput :: PPS [(Char, Position)]
getOutput = gets ppOutput
-- position accessors
getPosition :: PPS Position
getPosition = gets ppPosition
setPosition :: Position -> PPS ()
setPosition x = modify $ \s -> s { ppPosition = x }
-- file path accessors
getFilePath :: PPS FilePath
getFilePath = gets ppFilePath
setFilePath :: String -> PPS ()
setFilePath x = modify $ \s -> s { ppFilePath = x }
-- environment accessors
getEnv :: PPS Env
getEnv = gets ppEnv
setEnv :: Env -> PPS ()
setEnv x = modify $ \s -> s { ppEnv = x }
-- cond stack accessors
getCondStack :: PPS [Cond]
getCondStack = gets ppCondStack
setCondStack :: [Cond] -> PPS ()
setCondStack x = modify $ \s -> s { ppCondStack = x }
-- combined input and position accessors
setBuffer :: (String, Position) -> PPS ()
setBuffer (x, p) = do
    setInput x
    setPosition p
getBuffer :: PPS (String, Position)
getBuffer = do
    x <- getInput
    p <- getPosition
    return (x, p)

isIdentChar :: Char -> Bool
isIdentChar ch =
    ('a' <= ch && ch <= 'z') ||
    ('A' <= ch && ch <= 'Z') ||
    ('0' <= ch && ch <= '9') ||
    (ch == '_') || (ch == '$')

-- reads an identifier from the front of the input
takeIdentifier :: PPS String
takeIdentifier = do
    str <- getInput
    let (ident, rest) = span isIdentChar str
    advancePositions ident
    setInput rest
    return ident

-- read tokens after the name until the first (un-escaped) newline
takeUntilNewline :: PPS String
takeUntilNewline = do
    str <- getInput
    case str of
        []                 -> return ""
        '\n' :        _    -> do
            return ""
        '/' : '/' : _ -> do
            remainder <- takeThrough '\n'
            case last $ init remainder of
                '\\' -> takeUntilNewline >>= return . (' ' :)
                _ -> return ""
        '\\' : '\n' : rest -> do
            advancePosition '\\'
            advancePosition '\n'
            setInput rest
            takeUntilNewline >>= return . (' ' :)
        ch   :        rest -> do
            advancePosition ch
            setInput rest
            takeUntilNewline >>= return . (ch :)

-- select characters up to and including the given character
takeThrough :: Char -> PPS String
takeThrough goal = do
    str <- getInput
    if null str
        then lexicalError $
                "unexpected end of input, looking for " ++ (show goal)
        else do
            ch <- takeChar
            if ch == goal
                then return [ch]
                else do
                    rest <- takeThrough goal
                    return $ ch : rest

-- pop one character from the input stream
takeChar :: PPS Char
takeChar = do
    str <- getInput
    (ch, chs) <-
        if null str
            then lexicalError "unexpected end of input"
            else return (head str, tail str)
    advancePosition ch
    setInput chs
    return ch

-- removes and returns a quoted string such as <foo.bar> or "foo.bar"
takeQuotedString :: PPS String
takeQuotedString = do
    dropSpaces
    ch <- takeChar
    end <-
        case ch of
            '"' -> return '"'
            '<' -> return '>'
            _ -> lexicalError $ "bad beginning of include arg: " ++ (show ch)
    rest <- takeThrough end
    let res = ch : rest
    return res

-- removes and returns a decimal number
takeNumber :: PPS Int
takeNumber = do
    dropSpaces
    leadCh <- peekChar
    if '0' <= leadCh && leadCh <= '9'
        then step 0
        else lexicalError $ "expected number, but found unexpected char: "
                ++ show leadCh
    where
        step number = do
            ch <- peekChar
            if ch == ' ' || ch == '\n' then
                return number
            else if '0' <= ch && ch <= '9' then do
                _ <- takeChar
                let digit = ord ch - ord '0'
                step $ number * 10 + digit
            else
                lexicalError $ "unexpected char while reading number: "
                    ++ show ch

peekChar :: PPS Char
peekChar = do
    str <- getInput
    if null str
        then lexicalError "unexpected end of input"
        else return $ head str

takeMacroDefinition :: PPS (String, [(String, Maybe String)])
takeMacroDefinition = do
    leadCh <- peekChar
    if leadCh /= '('
        then do
            dropSpaces
            body <- takeUntilNewline
            return (body, [])
        else do
            args <- takeMacroArguments
            body <- takeUntilNewline
            argsWithDefaults <- mapM splitArg args
            if null args
                then lexicalError "macros cannot have 0 args"
                else return (body, argsWithDefaults)
    where
        splitArg :: String -> PPS (String, Maybe String)
        splitArg [] = lexicalError "macro defn. empty argument"
        splitArg str = do
            let (name, rest) = span isIdentChar str
            if null name || not (all isIdentChar name) then
                lexicalError $ "invalid macro arg name: " ++ show name
            else if null rest then
                return (name, Nothing)
            else do
                let trimmed = dropWhile isWhitespaceChar rest
                let leadCh = head trimmed
                if leadCh /= '='
                then lexicalError $ "bad char after arg name: " ++ (show leadCh)
                else return (name, Just $ tail trimmed)

-- commas and right parens are forbidden outside matched pairs of: (), [], {},
-- "", except to delimit arguments or end the list of arguments; see 22.5.1
takeMacroArguments :: PPS [String]
takeMacroArguments = do
    dropWhitespace
    leadCh <- takeChar
    if leadCh == '('
        then argLoop
        else lexicalError $ "expected begining of macro arguments, but found "
                ++ show leadCh
    where
        argLoop :: PPS [String]
        argLoop = do
            dropWhitespace
            (arg, isEnd) <- loop "" []
            let arg' = dropWhileEnd isWhitespaceChar arg
            if isEnd
                then return [arg']
                else do
                    rest <- argLoop
                    return $ arg' : rest
        loop :: String -> [Char] -> PPS (String, Bool)
        loop curr stack = do
            ch <- takeChar
            case (stack, ch) of
                (      s,'\\') -> do
                    ch2 <- takeChar
                    loop (curr ++ [ch, ch2]) s
                ([     ], ',') -> return (curr, False)
                ([     ], ')') -> return (curr, True)

                ('"' : s, '"') -> loop (curr ++ [ch]) s
                (      s, '"') -> loop (curr ++ [ch]) ('"' : s)
                ('[' : s, ']') -> loop (curr ++ [ch]) s
                (      s, '[') -> loop (curr ++ [ch]) ('[' : s)
                ('(' : s, ')') -> loop (curr ++ [ch]) s
                (      s, '(') -> loop (curr ++ [ch]) ('(' : s)
                ('{' : s, '}') -> loop (curr ++ [ch]) s
                (      s, '{') -> loop (curr ++ [ch]) ('{' : s)

                (      s,'\n') -> loop (curr ++ [' ']) s
                (      s, _  ) -> loop (curr ++ [ch ]) s

findUnescapedQuote :: String -> (String, String)
findUnescapedQuote [] = ([], [])
findUnescapedQuote ('`' : '\\' : '`' : '"' : rest) = ('\\' : '"' : start, end)
    where (start, end) = findUnescapedQuote rest
findUnescapedQuote ('\\' : '"' : rest) = ('\\' : '"' : start, end)
    where (start, end) = findUnescapedQuote rest
findUnescapedQuote ('"' : rest) = ("\"", rest)
findUnescapedQuote ('`' : '"' : rest) = ("\"", rest)
findUnescapedQuote (ch : rest) = (ch : start, end)
    where (start, end) = findUnescapedQuote rest

-- substitute in the arguments for a macro expansion
substituteArgs :: String -> [String] -> [String] -> String
substituteArgs "" _ _ = ""
substituteArgs ('`' : '`' : body) names args =
    substituteArgs body names args
substituteArgs ('"' : body) names args =
    '"' : start ++ substituteArgs rest names args
    where (start, rest) = findUnescapedQuote body
substituteArgs ('\\' : '"' : body) names args =
    '\\' : '"' : substituteArgs body names args
substituteArgs ('`' : '"' : body) names args =
    '"' : substituteArgs (init start) names args
    ++ '"' : substituteArgs rest names args
    where (start, rest) = findUnescapedQuote body
substituteArgs body names args =
    case span isIdentChar body of
        ([], _) -> head body : substituteArgs (tail body) names args
        (ident, rest) ->
            case elemIndex ident names of
                Nothing -> ident ++ substituteArgs rest names args
                Just idx -> (args !! idx) ++ substituteArgs rest names args

defaultMacroArgs :: [Maybe String] -> [String] -> PPS [String]
defaultMacroArgs [] [] = return []
defaultMacroArgs [] _ = lexicalError "too many macro arguments given"
defaultMacroArgs defaults [] = do
    if all isJust defaults
        then return $ map fromJust defaults
        else lexicalError "too few macro arguments given"
defaultMacroArgs (f : fs) (a : as) = do
    let arg = if a == "" && isJust f
            then fromJust f
            else a
    args <- defaultMacroArgs fs as
    return $ arg : args

-- drop spaces in the input until a non-space is reached or EOF
dropSpaces :: PPS ()
dropSpaces = do
    str <- getInput
    if null str then
        return ()
    else do
        let ch : rest = str
        if ch == '\t' || ch == ' ' then do
            advancePosition ch
            setInput rest
            dropSpaces
        else
            return ()

isWhitespaceChar :: Char -> Bool
isWhitespaceChar ch = elem ch [' ', '\t', '\n']

-- drop all leading whitespace in the input
dropWhitespace :: PPS ()
dropWhitespace = do
    str <- getInput
    case str of
        ch : chs ->
            if isWhitespaceChar ch
                then do
                    advancePosition ch
                    setInput chs
                    dropWhitespace
                else return ()
        [] -> return ()

-- directives that must always be processed even if the current code block is
-- being excluded; we have to process conditions so we can match them up with
-- their ending tag, even if they're being skipped
unskippableDirectives :: [String]
unskippableDirectives = ["else", "elsif", "endif", "ifdef", "ifndef"]

-- list of all of the supported directive names; used to prevent defining macros
-- with illegal names
directives :: [String]
directives =
    [ "timescale"
    , "celldefine"
    , "endcelldefine"
    , "unconnected_drive"
    , "nounconnected_drive"
    , "default_nettype"
    , "pragma"
    , "resetall"
    , "begin_keywords"
    , "end_keywords"
    , "__FILE__"
    , "__LINE__"
    , "line"
    , "include"
    , "ifdef"
    , "ifndef"
    , "else"
    , "elsif"
    , "endif"
    , "define"
    , "undef"
    , "undefineall"
    ]

-- primary preprocessor loop
preprocessInput :: PPS ()
preprocessInput = do
    str <- getInput
    case str of
        '/' : '/' : _ -> removeThrough "\n"
        '/' : '*' : _ -> removeThrough "*/"
        '`' : _ -> handleDirective
        ch : chs -> do
            pos <- getPosition
            advancePosition ch
            setInput chs
            condStack <- getCondStack
            if any (/= CurrentlyTrue) condStack
                then return ()
                else pushChar ch pos
        [] -> return ()
    if str == []
        then return ()
        else preprocessInput

handleDirective :: PPS ()
handleDirective = do
    directivePos <- getPosition
    '`' <- takeChar
    directive <- takeIdentifier

    -- helper for directives which are not operated on
    let passThrough = do
            pushChar '`' directivePos
            _ <- mapM (flip pushChar directivePos) directive
            return ()

    env <- getEnv
    condStack <- getCondStack
    if any (/= CurrentlyTrue) condStack
        && not (elem directive unskippableDirectives)
    then return ()
    else case directive of

        "timescale" -> removeThrough "\n"

        "celldefine" -> passThrough
        "endcelldefine" -> passThrough

        "unconnected_drive" -> passThrough
        "nounconnected_drive" -> passThrough

        "default_nettype" -> passThrough
        "pragma" -> do
            leadCh <- peekChar
            if leadCh == '\n'
                then lexicalError "pragma directive cannot be empty"
                else removeThrough "\n"
        "resetall" -> passThrough

        "begin_keywords" -> passThrough
        "end_keywords" -> passThrough

        "__FILE__" -> do
            currFile <- getFilePath
            insertChars directivePos (show currFile)
        "__LINE__" -> do
            Position _ currLine _ <- getPosition
            insertChars directivePos (show currLine)

        "line" -> do
            lineLookahead
            lineNumber <- takeNumber
            quotedFilename <- takeQuotedString
            levelNumber <- takeNumber
            let filename = init $ tail quotedFilename
            setFilePath filename
            let newPos = Position filename lineNumber 0
            setPosition newPos
            if 0 <= levelNumber && levelNumber <= 2
                then return ()
                else lexicalError "line directive invalid level number"

        "include" -> do
            lineLookahead
            quotedFilename <- takeQuotedString
            fileFollow <- getFilePath
            bufFollow <- getBuffer
            -- find and load the included file
            let filename = init $ tail quotedFilename
            includePath <- includeSearch filename
            includeContent <- liftIO $ loadFile includePath
            -- pre-process the included file
            setFilePath includePath
            setBuffer (includeContent, Position includePath 1 1)
            preprocessInput
            -- resume processing the original file
            setFilePath fileFollow
            setBuffer bufFollow

        "ifdef" -> do
            dropSpaces
            name <- takeIdentifier
            let newCond = if Map.member name env
                    then CurrentlyTrue
                    else NeverTrue
            setCondStack $ newCond : condStack
        "ifndef" -> do
            dropSpaces
            name <- takeIdentifier
            let newCond = if Map.notMember name env
                    then CurrentlyTrue
                    else NeverTrue
            setCondStack $ newCond : condStack
        "else" -> do
            let newCond = if head condStack == NeverTrue
                    then CurrentlyTrue
                    else NeverTrue
            setCondStack $ newCond : tail condStack
        "elsif" -> do
            dropSpaces
            name <- takeIdentifier
            let currCond = head condStack
            let newCond =
                    if currCond /= NeverTrue then
                        PreviouslyTrue
                    else if Map.member name env then
                        CurrentlyTrue
                    else
                        NeverTrue
            setCondStack $ newCond : tail condStack
        "endif" -> do
            setCondStack $ tail condStack

        "define" -> do
            dropSpaces
            name <- do
                str <- takeIdentifier
                if elem str directives
                    then lexicalError $ "illegal macro name: " ++ str
                    else return str
            defn <- do
                str <- getInput
                if null str
                    then return ("", [])
                    else takeMacroDefinition
            setEnv $ Map.insert name defn env
        "undef" -> do
            dropSpaces
            name <- takeIdentifier
            setEnv $ Map.delete name env
        "undefineall" -> do
            setEnv Map.empty

        _ -> do
            case Map.lookup directive env of
                Nothing -> lexicalError $ "Undefined macro: " ++ directive
                Just (body, formalArgs) -> do
                    replacement <- if null formalArgs
                        then return body
                        else do
                            actualArgs <- takeMacroArguments
                            defaultedArgs <- defaultMacroArgs (map snd formalArgs) actualArgs
                            return $ substituteArgs body (map fst formalArgs) defaultedArgs
                    -- save our current state
                    currFile <- getFilePath
                    bufFollow <- getBuffer
                    -- lex the macro expansion, preserving the file and line
                    let Position _ l c = snd bufFollow
                    let loc = "macro expansion of " ++ directive ++ " at " ++ currFile
                    let pos = Position loc l (c - length directive - 1)
                    setBuffer (replacement, pos)
                    preprocessInput
                    -- return to the rest of the input
                    setBuffer bufFollow

-- inserts the given string into the output at the given position
insertChars :: Position -> String -> PPS ()
insertChars pos str = do
    bufFollow <- getBuffer
    setBuffer (str, pos)
    preprocessInput
    setBuffer bufFollow

-- pre-pre-processes the current line, such that macros can be used in
-- directives
lineLookahead :: PPS ()
lineLookahead = do
    line <- takeUntilNewline
    -- save the state
    outputOrig <- gets ppOutput
    condStackOrig <- getCondStack
    inputOrig <- getInput
    -- process the line
    setOutput []
    setCondStack []
    setInput line
    preprocessInput
    outputAfter <- getOutput
    -- add in the new characters
    let newChars = reverse $ map fst outputAfter
    setInput $ newChars ++ inputOrig
    -- restore the previous state
    setOutput outputOrig
    setCondStack condStackOrig

-- update the position in the preprocessor state according to the movement of
-- the given character
advancePosition :: Char -> PPS ()
advancePosition '\n' = do
    Position f l _ <- getPosition
    setPosition $ Position f (l + 1) 1
advancePosition _ = do
    Position f l c <- getPosition
    setPosition $ Position f l (c + 1)

-- advances position for multiple characters
advancePositions :: String -> PPS ()
advancePositions str = do
    _ <- mapM advancePosition str
    return ()

-- adds a character (and its position) to the output state
pushChar :: Char -> Position -> PPS ()
pushChar c p = do
    output <- getOutput
    setOutput $ (c, p) : output

-- search for a pattern in the input and remove remove characters up to and
-- including the first occurrence of the pattern
removeThrough :: String -> PPS ()
removeThrough pattern = do
    str <- getInput
    case findIndex (isPrefixOf pattern) (tails str) of
        Nothing ->
            if pattern == "\n"
                then setInput ""
                else lexicalError $ "Reached EOF while looking for: "
                        ++ show pattern
        Just patternIdx -> do
            let chars = patternIdx + length pattern
            let (dropped, rest) = splitAt chars str
            advancePositions dropped
            setInput rest
