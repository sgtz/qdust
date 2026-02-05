/ qdust.q - Q/K Expect Test Runner
/ dune-style expect tests for Q/K with diff/promote workflow

/ Designed to sit alongside other testing frameworks (e.g. qspec).
/ Use qdust for expect/snapshot tests, qspec for property-based tests, etc.

/ Usage:
/   q qdust.q test file.q       Run tests, show diffs, exit 1 if failures
/   q qdust.q diff file.q       Show diffs only
/   q qdust.q promote file.q    Accept .corrected as new expected
/   q qdust.q --json test file.q   Output in JSON format

\d .qd

/ ============================================================================
/ Configuration
/ ============================================================================

verbose:0b
json:0b
junit:0b
batchdiffs:0b     / Batch mode: generate .corrected but don't print diffs (qdust handles)
autoMergeNew:0b   / Auto-promote if only new tests (no modified/errors)
errorsOnly:0b     / Only show errors, not full output
listci:0b         / CI-clickable error format
filterFn:`       / Filter tests by function name (` = no filter)

/ External diff tool via QDUST_DIFF env var (e.g. "code --diff", "idea diff")
launchDiff:{[orig;corrected]
  d:getenv`QDUST_DIFF;
  if[0<count d;system d," \"",orig,"\" \"",corrected,"\" &";:1b];
  0b}

/ Custom loader - override this in your init file for custom loading schemes
/ Default: system "l file.q"
customloader:{[file] system"l ",file}

/ Init file path (set via --init or QDUST_INIT)
initFile:""

/ ============================================================================
/ Test Discovery
/ ============================================================================

/ Find test files in directory (recursive)
/ Returns list of .q and .t files
findTestFiles:{[path]
  / Normalize path
  p:$["/"=last path;-1_path;path];
  / Use find command for recursive search - filter patterns in find itself
  cmd:"find \"",p,"\" -type f \\( -name \"*.q\" -o -name \"*.t\" \\) ";
  cmd:cmd,"! -path \"*/.git/*\" ! -path \"*/node_modules/*\" ! -name \"*qdust*\" 2>/dev/null | sort";
  files:@[system;cmd;{()}];
  files}

/ Check if path is directory
isDir:{[path] $[()~key hsym`$path;0b;11h=type key hsym`$path]}

/ Check if path looks like a glob pattern
isGlob:{[path] 0<sum path in"*?[]"}

/ Expand glob pattern using bash (supports ** with globstar)
expandGlob:{[pattern]
  / Use bash with globstar for ** support
  cmd:"bash -c 'shopt -s globstar nullglob 2>/dev/null; ls -d ",pattern," 2>/dev/null' | grep -E \"[.](q|t)$\"";
  @[system;cmd;{()}]}

/ ============================================================================
/ String Utilities
/ ============================================================================

/ Value to string - two formats:
/ s1: compact (-3!) for inline arrow tests - single line
/ s1Pretty: console (.Q.s) for REPL/block tests - multiline tables
s1:{-3!x}
s1Pretty:{r:.Q.s x;while[(0<count r)&"\n"=last r;r:-1_r];r}

/ Find "->" in string (with or without spaces)
/ Quote-aware: finds first arrow where quotes before it are balanced
splitArrow:{
  / Find first arrow position where quote count is even (outside string)
  findBalanced:{[s;sep]
    idxs:ss[s;sep];
    if[0=count idxs;:-1];
    i:0;
    while[i<count idxs;
      pos:idxs i;
      nq:sum(pos#s)="\"";
      if[0=nq mod 2;:pos];
      i:i+1];
    -1};
  / Try " -> " first
  pos:findBalanced[x;" -> "];
  if[pos>=0;:(trim pos#x;trim(4+pos)_x)];
  / Try "->" without spaces
  pos:findBalanced[x;"->"];
  if[pos>=0;:(trim pos#x;trim(2+pos)_x)];
  ()}

/ Check string prefix
startsWith:{$[(count y)>count x;0b;y~(count y)#x]}

/ JSON escape
jsonEscape:{r:x;r:ssr[r;"\\";"\\\\"];r:ssr[r;"\"";"\\\""];r:ssr[r;"\n";"\\n"];r:ssr[r;"\r";"\\r"];r:ssr[r;"\t";"\\t"];r}

/ ============================================================================
/ Parsing - Detection Functions
/ ============================================================================

defaultSection:`name`line`ci!(`$"(default)";0;`default)

isSection:{t:trim x;$[startsWith[t;"/// # "];1b;startsWith[t;"/ # "];1b;startsWith[t;"# "];1b;0b]}
parseSection:{t:trim x;$[startsWith[t;"/// # "];6_t;startsWith[t;"/ # "];4_t;startsWith[t;"# "];2_t;t]}

/ Directives: /@ci:value, /@fn:name (paste-safe - always a Q comment)
isCiTag:{t:trim x;startsWith[t;"/@ci:"]}
parseCiTag:{t:trim x;`$lower 5_t}  / drop "/@ci:", result is required/optional/skip

isFnTag:{t:trim x;startsWith[t;"/@fn:"]}
parseFnTag:{t:trim x;r:5_t;`$trim r}  / drop "/@fn:", trim - empty string gives `

/ Detect function definition: name:{...} or name:func or name:.ns.func
/ Returns function name as symbol, or ` if not a function definition
parseFnDef:{[line]
  t:trim line;
  if[0=count t;:`];
  if[t[0]="/";:`];  / comment
  / Look for name:{
  i:ss[t;":"];
  if[0=count i;:`];
  colon:first i;
  if[colon<1;:`];  / need at least 1 char before :
  name:colon#t;
  / Validate name: alphanumeric, dots, underscores
  if[not all name in"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._";:`];
  if[name[0]in"0123456789";:`];  / can't start with digit
  / Check what follows the colon
  rest:trim(colon+1)_t;
  if[0=count rest;:`];
  / Function def if starts with { or is assignment of another function
  if[rest[0]="{";:`$name];
  / Could be assigning an existing function (name:existingFunc)
  / We'll be conservative and only match :{
  `}

/ Test line detection:
/   - /// prefix = always a test (block or inline)
/   - // prefix = only a test if contains ->
/   - single / = not a test (regular comment)
isTestLine:{t:trim x;
  if[0=count t;:0b];
  if[not t[0]="/";:0b];
  / /// prefix is always a test
  if[startsWith[t;"///"];:1b];
  / // prefix only if contains ->
  if[startsWith[t;"//"];:0<count ss[t;"->"]];
  / single / is never a test
  0b}
/ Strip leading "/" characters to get test content
stripSlashes:{t:trim x;while[(0<count t)&t[0]="/";t:1_t];trim t}
/ Extract prefix (slashes + spaces) from comment line
getPrefix:{t:trim x;i:0;while[(i<count t)&t[i]="/";i:i+1];while[(i<count t)&t[i]=" ";i:i+1];i#t}
isReplTest:{$[2>count x;0b;((x[0]="q")&x[1]=")")|((x[0]="k")&x[1]=")")]}

/ Check if expression ends with ; (suppresses output, like Q console)
isSilentExpr:{[expr]
  t:trim expr;
  if[0=count t;:0b];
  / Strip trailing comment (/ ...)
  slashPos:ss[t;" /"];
  if[0<count slashPos;t:trim(first slashPos)#t];
  / Check if ends with semicolon
  if[0=count t;:0b];
  ";"=last t}

/ ============================================================================
/ Parsing - File Parsers (iterative, CQ-compatible)
/ ============================================================================

/ Check if content (after stripping slashes) is REPL format: q)expr or k)expr
isReplContent:{[content] $[2>count content;0b;((content[0]="q")&content[1]=")")|((content[0]="k")&content[1]=")")]}

/ Collect expected lines for REPL test in .q file - returns (lines;newIndex)
/ Expected lines must start with /// (or //) - strip prefix
/ Ends at: next q), k), line with ->, comment line, or non-comment line
collectQReplExpected:{[allLines;startIdx]
  n:count allLines;
  collected:1_enlist"";
  idx:startIdx;
  done:0b;
  while[(idx<n)&not done;
    line:allLines idx;
    t:trim line;
    / Must be a comment line
    if[not isTestLine t;done:1b];
    if[not done;
      content:stripSlashes t;
      / End conditions: q), k), or contains ->
      $[isReplContent content;done:1b;
        0<count ss[content;"->"];done:1b;
        [collected:collected,enlist content;idx:idx+1]]]];
  / Trim trailing blank lines - adjust idx to preserve them in output
  trimmed:0;
  while[(0<count collected)&0=count trim last collected;collected:-1_collected;trimmed:trimmed+1];
  (collected;idx-trimmed)}

/ Parse .q file - returns (lines;tests)
parseQFile:{[file]
  lines:read0 hsym`$file;
  n:count lines;
  tests:1_enlist`line`expr`expected`endLine`format`section`isSilent`prefix`fn!(0;"";"";0;`;defaultSection;0b;"";`);
  sec:defaultSection;
  curFn:`;  / current function context (from @fn or last defined function)
  i:0;
  while[i<n;
    line:lines i;
    t:trim line;
    ln:i+1;
    / Check for function definition (sets implicit context)
    fnDef:parseFnDef line;
    $[not fnDef~`;
      [curFn:fnDef;i:i+1];
      isSection t;
      [sec:`name`line`ci!(parseSection t;ln;`default);i:i+1];
      isCiTag t;
      [sec:@[sec;`ci;:;parseCiTag t];i:i+1];
      isFnTag t;
      [curFn:parseFnTag t;i:i+1];  / explicit @fn directive
      isTestLine t;
      [content:stripSlashes t;
       pfx:getPrefix t;  / extract exact prefix (slashes + spaces)
       / Check for REPL format: q)expr or k)expr
       $[isReplContent content;
         [mode:$[content[0]="k";`k;`q];
          expr:2_content;
          / Check for inline REPL: q)expr -> result
          arrow:splitArrow expr;
          $[0<count arrow;
            [tests:tests,enlist`line`expr`expected`endLine`format`section`mode`isSilent`prefix`fn!(ln;arrow 0;arrow 1;i;`inline;sec;mode;0b;pfx;curFn);
             i:i+1];
            / Trailing semicolon = no output expected
            isSilentExpr[expr];
            [tests:tests,enlist`line`expr`expected`endLine`format`section`mode`isSilent`prefix`fn!(ln;expr;"";i;`silent;sec;mode;1b;pfx;curFn);
             i:i+1];
            [i:i+1;
             replResult:collectQReplExpected[lines;i];
             expLines:replResult 0;
             i:replResult 1;
             tests:tests,enlist`line`expr`expected`endLine`format`section`mode`isSilent`prefix`fn!(ln;expr;"\n"sv expLines;i;`repl;sec;mode;0b;pfx;curFn)]]];
         / Check for inline: expr -> result
         [arrow:splitArrow content;
          if[0<count arrow;
            tests:tests,enlist`line`expr`expected`endLine`format`section`mode`isSilent`prefix`fn!(ln;arrow 0;arrow 1;i;`inline;sec;`q;0b;pfx;curFn)];
          i:i+1]]];
      i:i+1]];
  (lines;tests)}

/ Check if line is inline test format: expr -> result
isInlineTest:{[line]
  t:trim line;
  / Skip empty, comments, REPL lines
  if[0=count t;:0b];
  if[t[0]="/";:0b];
  if[isReplTest t;:0b];
  / Must contain ->
  0<count ss[t;"->"]}

/ Collect REPL expected lines - returns (lines;newIndex)
/ Stops at next REPL test, inline test, or comment line
collectReplExpected:{[allLines;startIdx]
  n:count allLines;
  collected:1_enlist"";
  idx:startIdx;
  done:0b;
  while[(idx<n)&not done;
    line:allLines idx;
    t:trim line;
    / Stop at REPL test, inline test, or comment
    $[(isReplTest line)|isInlineTest line;done:1b;
      (0<count t)&t[0]="/";done:1b;
      [collected:collected,enlist line;idx:idx+1]]];
  / Trim trailing blank lines - adjust idx to preserve them in output
  trimmed:0;
  while[(0<count collected)&0=count trim last collected;collected:-1_collected;trimmed:trimmed+1];
  (collected;idx-trimmed)}

/ Parse .t file (REPL style + inline) - returns (lines;tests)
parseTFile:{[file]
  lines:read0 hsym`$file;
  n:count lines;
  tests:1_enlist`line`expr`expected`endLine`format`section`mode`isSilent`prefix`fn!(0;"";"";0;`;defaultSection;`q;0b;"";`);
  sec:defaultSection;
  curFn:`;  / current function context
  i:0;
  while[i<n;
    line:lines i;
    ln:i+1;
    $[isCiTag line;
      [sec:@[sec;`ci;:;parseCiTag line];i:i+1];
      isFnTag line;
      [curFn:parseFnTag line;i:i+1];
      isReplTest line;
      [mode:$[line[0]="k";`k;`q];
       rest:2_line;
       / Check if REPL line has inline result: q)expr -> result
       arrow:splitArrow rest;
       $[0<count arrow;
         [test:`line`expr`expected`endLine`format`section`mode`isSilent`prefix`fn!(ln;arrow 0;arrow 1;i;`inline;sec;mode;0b;"";curFn);
          tests:tests,enlist test;
          i:i+1];
         / Trailing semicolon = no output expected
         isSilentExpr[rest];
         [test:`line`expr`expected`endLine`format`section`mode`isSilent`prefix`fn!(ln;rest;"";i;`silent;sec;mode;1b;"";curFn);
          tests:tests,enlist test;
          i:i+1];
         [i:i+1;
          replResult:collectReplExpected[lines;i];
          expLines:replResult 0;
          i:replResult 1;
          test:`line`expr`expected`endLine`format`section`mode`isSilent`prefix`fn!(ln;rest;"\n"sv expLines;i;`repl;sec;mode;0b;"";curFn);
          tests:tests,enlist test]]];
      isInlineTest line;
      [arrow:splitArrow line;
       if[0<count arrow;
         test:`line`expr`expected`endLine`format`section`mode`isSilent`prefix`fn!(ln;arrow 0;arrow 1;i;`inline;sec;`q;0b;"";curFn);
         tests:tests,enlist test];
       i:i+1];
      i:i+1]];
  (lines;tests)}

/ ============================================================================
/ Execution
/ ============================================================================

/ Evaluate expression with format choice
/ pretty=1b uses .Q.s (multiline tables), pretty=0b uses -3! (compact)
evalExpr:{[expr;pretty]
  / Note: Per-expression timeout is not supported in pure Q
  / Use external tools (e.g., timeout command) to wrap qdust if needed
  r:@[value;expr;{(`err;x)}];
  fmt:$[pretty;s1Pretty;s1];
  $[(`err)~first r;("";"'",last r);(fmt r;"")]}

loadFile:{[file]
  @[{customloader x;`ok};file;{(`fail;x)}]}

/ Parse @load directives from file lines
/ Handles: / @load, // @load, /// @load, with variable spacing
/ Returns list of files to load
parseLoadDirectives:{[lines]
  / Match lines starting with one or more /, optional spaces, then @load
  isLoadDir:{[line]
    t:trim line;
    if[0=count t;:0b];
    if[not t[0]="/";:0b];
    / Strip leading slashes
    while[(0<count t)&t[0]="/";t:1_t];
    / Check for @load after optional whitespace
    t:trim t;
    t like"@load *"};
  dirs:lines where isLoadDir each lines;
  / Extract filename: strip slashes, trim, drop "@load "
  extractFile:{[line]
    t:trim line;
    while[(0<count t)&t[0]="/";t:1_t];
    t:trim t;
    trim 6_t};  / drop "@load "
  extractFile each dirs}

/ Get paired .q file for a .t file (foo.t -> foo.q)
getPairedFile:{[tfile]
  if[not tfile like"*.t";:""];
  qfile:(-2_tfile),".q";
  if[()~key hsym`$qfile;:""];
  qfile}

/ Load dependencies for a test file
/ 1. Paired .q file (if .t file)
/ 2. @load directives in file
loadDeps:{[file;lines]
  / Load paired file first (for .t files)
  paired:getPairedFile file;
  if[0<count paired;
    r:loadFile paired;
    if[`fail~first r;:r]];
  / Load @load directives
  deps:parseLoadDirectives lines;
  i:0;
  while[i<count deps;
    r:loadFile deps i;
    if[`fail~first r;:r];
    i:i+1];
  `ok}

/ Check if expected is a "new test" placeholder
/ Placeholder: "*" (or empty for block tests)
isNewTest:{[expected]
  t:trim expected;
  (0=count t)|(t~enlist"*")}

/ Determine change type for a test result
/ Returns: `new`modified`unchanged`error
/ Normalize string for comparison: trim each line, remove trailing blank lines
normalize:{s:"\n"sv trim each"\n"vs x;while[(0<count s)&"\n"~last s;s:-1_s];s}

getChangeType:{[test;actual;error]
  / If error, compare expected with error message (allows testing for specific errors)
  $[0<count error;
    $[isNewTest test[`expected];`new;
      (normalize test[`expected])~normalize error;`unchanged;
      `error];
    isNewTest test[`expected];`new;
    (normalize test[`expected])~normalize actual;`unchanged;
    `modified]}

runTests:{[file;tests;shouldLoad]
  if[shouldLoad;
    r:loadFile file;
    if[`fail~first r;
      (hsym`$(file,".failed"))0:enlist r 1;
      -2"Error: Failed to load ",file,": ",r 1;
      :(::)]];
  results:();
  i:0;
  while[i<count tests;
    t:tests i;
    isSilent:$[`isSilent in key t;t[`isSilent];0b];
    / inline uses -3! (compact), repl/block uses .Q.s (pretty)
    pretty:t[`format]in`repl`block;
    $[`skip~t[`section][`ci];
      results:results,enlist t,`actual`error`passed`skipped`changeType!("";"";1b;1b;`skip);
      isSilent;
      [r:evalExpr[t[`expr];0b];
       / Semicolon statement: pass if no error
       passed:0=count r 1;
       changeType:$[passed;`silent;`error];
       results:results,enlist t,`actual`error`passed`skipped`changeType!(r 0;r 1;passed;0b;changeType)];
      [r:evalExpr[t[`expr];pretty];
       changeType:getChangeType[t;r 0;r 1];
       / New tests always "pass" (we're capturing the result)
       passed:$[changeType in`new`unchanged;1b;0b];
       results:results,enlist t,`actual`error`passed`skipped`changeType!(r 0;r 1;passed;0b;changeType)]];
    i:i+1];
  results}

/ ============================================================================
/ Section Summaries
/ ============================================================================

computeSummaries:{[results]
  / Single section version - simplified for CQ
  n:count results;
  firstSec:(results 0)[`section];
  p:0j;s:0j;nw:0j;md:0j;er:0j;st:0j;i:0;
  while[i<n;
    r:results i;
    p:p+`long$r[`passed];
    s:s+`long$r[`skipped];
    ct:r[`changeType];
    $[ct~`new;nw:nw+1;
      ct~`modified;md:md+1;
      ct~`error;er:er+1;
      ct~`silent;st:st+1;
      ()];
    i:i+1];
  f:md+er;  / Failed = modified + error
  enlist `section`total`passed`failed`skipped`new`modified`errors`silent!(firstSec;`long$n;p;f;s;nw;md;er;st)}

ciStr:{$[x~`required;"required";x~`optional;"optional";x~`skip;"skip";""]}

/ ============================================================================
/ Output - Text
/ ============================================================================

printDiff:{[file;r]
  ci:$[`default~r[`section][`ci];"";" [ci:",ciStr[r[`section][`ci]],"]"];
  secname:r[`section][`name];
  / secname may be string or symbol - handle both
  secstr:$[10h=type secname;secname;-11h=type secname;string secname;""];
  sec:$[(secstr~"(default)")|(0=count secstr);"";" (",secstr,")"];
  ct:$[`changeType in key r;r[`changeType];`];
  tag:$[ct~`new;" [NEW]";ct~`modified;" [MODIFIED]";ct~`error;" [ERROR]";""];
  -1"";
  -1"File \"",file,"\", line ",string[r[`line]],", characters 0-0:",sec,ci,tag;
  -1"  Expression: ",r[`expr];
  $[ct~`new;
    -1"  Result:     ",r[`actual];
    [if[0<count r[`expected];-1"  Expected:   ",r[`expected]];
     $[0<count r[`error];-1"  Error:      ",r[`error];-1"  Actual:     ",r[`actual]]]];}

formatErrorLine:{[file;r]
  ci:$[`default~r[`section][`ci];"";"[ci:",ciStr[r[`section][`ci]],"] "];
  secname:r[`section][`name];
  secstr:$[10h=type secname;secname;-11h=type secname;string secname;""];
  sec:$[(secstr~"(default)")|(0=count secstr);"";secstr,": "];
  got:$[0<count r[`error];"error: ",first"\n"vs r[`error];r[`actual]];
  file,":",string[r[`line]],": ",sec,ci,r[`expr]," -> ",r[`expected]," (got: ",got,")"}

/ CI-clickable format: File "path", line N: expr -> expected (got: actual)
formatCiError:{[file;r]
  got:$[0<count r[`error];"error: ",first"\n"vs r[`error];r[`actual]];
  "File \"",file,"\", line ",string[r[`line]],": ",r[`expr]," -> ",r[`expected]," (got: ",got,")"}

printErrors:{[file;failed]
  if[0<count failed;
    -1"\n--- Errors ---";
    i:0;
    while[i<count failed;
      -1 formatErrorLine[file;failed i];
      i:i+1]]}

printSectionSummaries:{[summaries]
  -1"\n--- Sections ---";
  i:0;
  while[i<count summaries;
    s:summaries i;
    ci:$[`default~s[`section][`ci];"";" [ci:",ciStr[s[`section][`ci]],"]"];
    secname:s[`section][`name];
    secstr:$[10h=type secname;secname;-11h=type secname;string secname;"(default)"];
    $[(s[`skipped])=s[`total];
      -1"  [SKIP] ",secstr,": ",string[s[`total]]," skipped",ci;
      -1"  [",$[0=s[`failed];"PASS";"FAIL"],"] ",secstr,": ",string[s[`passed]],"/",string[s[`total]],ci];
    i:i+1]}

printSummary:{[file;summaries]
  tp:sum summaries[`passed];tf:sum summaries[`failed];ts:sum summaries[`skipped];
  tnew:sum summaries[`new];tmod:sum summaries[`modified];terr:sum summaries[`errors];
  -1"\n--- Summary ---";
  -1"  File: ",file;
  -1"  Passed: ",string tp;
  -1"  Failed: ",string tf;
  if[0<tnew;-1"    New:      ",string tnew];
  if[0<tmod;-1"    Modified: ",string tmod];
  if[0<terr;-1"    Errors:   ",string terr];
  if[0<ts;-1"  Skipped: ",string ts];
  -1"  Total: ",string tp+tf+ts;
  $[0<tmod|terr;
    -1"\nRun 'q qdust.q promote ",file,"' to accept changes.";
    0<tnew;
    -1"\nNew tests captured. Run 'q qdust.q promote ",file,"' to accept.";
    ()]}

/ ============================================================================
/ Output - JSON
/ ============================================================================

printJson:{[file;summaries;failed;corrFile]
  tp:sum summaries[`passed];tf:sum summaries[`failed];ts:sum summaries[`skipped];
  tnew:sum summaries[`new];tmod:sum summaries[`modified];terr:sum summaries[`errors];
  -1"{";
  -1"  \"file\": \"",jsonEscape[file],"\",";
  -1"  \"passed\": ",string[tp],",";
  -1"  \"failed\": ",string[tf],",";
  -1"  \"new\": ",string[tnew],",";
  -1"  \"modified\": ",string[tmod],",";
  -1"  \"errors\": ",string[terr],",";
  -1"  \"skipped\": ",string[ts],",";
  -1"  \"total\": ",string[tp+tf+ts],",";
  -1"  \"corrected_file\": \"",jsonEscape[corrFile],"\",";
  -1"  \"sections\": [";
  i:0;
  while[i<count summaries;
    s:summaries i;
    ci:$[`default~s[`section][`ci];"default";ciStr s[`section][`ci]];
    st:$[(s[`skipped])=s[`total];"skip";0=s[`failed];"pass";"fail"];
    cm:$[i<(count summaries)-1;",";""];
    -1"    {\"name\": \"",jsonEscape[string s[`section][`name]],"\", \"status\": \"",st,"\", \"passed\": ",string[s[`passed]],", \"failed\": ",string[s[`failed]],", \"skipped\": ",string[s[`skipped]],", \"ci\": \"",ci,"\"}",cm;
    i:i+1];
  -1"  ],";
  -1"  \"errors\": [";
  i:0;
  while[i<count failed;
    r:failed i;
    ci:$[`default~r[`section][`ci];"default";ciStr r[`section][`ci]];
    em:$[0<count r[`error];jsonEscape r[`error];""];
    cm:$[i<(count failed)-1;",";""];
    -1"    {\"line\": ",string[r[`line]],", \"section\": \"",jsonEscape[string r[`section][`name]],"\", \"ci\": \"",ci,"\", \"expr\": \"",jsonEscape[r[`expr]],"\", \"expected\": \"",jsonEscape[r[`expected]],"\", \"actual\": \"",jsonEscape[r[`actual]],"\", \"error\": \"",em,"\"}",cm;
    i:i+1];
  -1"  ]";
  -1"}"}

/ ============================================================================
/ Output - JUnit XML
/ ============================================================================

/ XML escape for JUnit output
xmlEscape:{r:x;r:ssr[r;"&";"&amp;"];r:ssr[r;"<";"&lt;"];r:ssr[r;">";"&gt;"];r:ssr[r;"\"";"&quot;"];r}

printJunit:{[file;summaries;results]
  tp:sum summaries[`passed];tf:sum summaries[`failed];ts:sum summaries[`skipped];
  total:tp+tf+ts;
  -1"<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
  -1"<testsuites tests=\"",string[total],"\" failures=\"",string[tf],"\" skipped=\"",string[ts],"\">";
  -1"  <testsuite name=\"",xmlEscape[file],"\" tests=\"",string[total],"\" failures=\"",string[tf],"\" skipped=\"",string[ts],"\">";
  i:0;
  while[i<count results;
    r:results i;
    name:xmlEscape r[`expr];
    classname:xmlEscape[file],":",string r[`line];
    $[r[`skipped];
      -1"    <testcase name=\"",name,"\" classname=\"",classname,"\"><skipped/></testcase>";
      r[`passed];
      -1"    <testcase name=\"",name,"\" classname=\"",classname,"\"/>";
      [msg:$[0<count r[`error];xmlEscape r[`error];"expected: ",xmlEscape[r[`expected]]," got: ",xmlEscape[r[`actual]]];
       -1"    <testcase name=\"",name,"\" classname=\"",classname,"\">";
       -1"      <failure message=\"",msg,"\"/>";
       -1"    </testcase>"]];
    i:i+1];
  -1"  </testsuite>";
  -1"</testsuites>"}

/ ============================================================================
/ File Generation
/ ============================================================================

writeCorrected:{[file;lines;results]
  corrs:(`long$results[`line])!results;
  n:count lines;
  out:();
  i:0;
  while[i<n;
    ln:i+1;
    $[ln in key corrs;
      [r:corrs ln;
       cpfx:$[`prefix in key r;r[`prefix];""];  / comment prefix (empty for .t, "/// " for .q)
       $[`inline~r[`format];
         [act:$[0<count r[`error];r[`error];r[`actual]];  / error already has ' prefix
          $["\n"in act;
            out:out,enlist[cpfx,r[`expr]],cpfx,/:"\n"vs act;
            out:out,enlist cpfx,r[`expr]," -> ",act];
          i:i+1];
         `block~r[`format];
         [act:$[0<count r[`error];r[`error];r[`actual]];  / error already has ' prefix
          i2:r[`endLine];
          out:out,enlist[lines i],cpfx,/:"\n"vs act;
          i:i2];
         `repl~r[`format];
         [rpfx:$[`k~r[`mode];"k)";"q)"];
          act:$[0<count r[`error];r[`error];r[`actual]];  / error already has ' prefix
          i2:r[`endLine];
          out:out,enlist[cpfx,rpfx,r[`expr]],cpfx,/:"\n"vs act;
          i:i2];
         `silent~r[`format];
         [rpfx:$[`k~r[`mode];"k)";"q)"];
          / Statement with error: show error underneath
          $[0<count r[`error];
            out:out,enlist[cpfx,rpfx,r[`expr]],enlist[cpfx,r[`error]];
            out:out,enlist[cpfx,rpfx,r[`expr]]];  / no error, just the statement
          i:i+1];
         [out:out,enlist lines i;i:i+1]]];
      [out:out,enlist lines i;i:i+1]]];
  cf:file,".corrected";
  (hsym`$cf)0:out;
  cf}

/ ============================================================================
/ CI Exit Code
/ ============================================================================

ciExitCode:{[summaries]
  / Exit 1 only for modified/error, not for new tests
  rf:0b;
  i:0;
  while[i<count summaries;
    s:summaries i;
    realFail:(s[`modified]+s[`errors])>0;
    if[realFail&s[`section][`ci]in`required`default;rf:1b];
    i:i+1];
  $[rf;1;0]}

/ ============================================================================
/ Commands
/ ============================================================================

/ Test a single file - returns (passed;failed;exitCode) instead of exiting
cmdTestSingle:{[file]
  isT:file like"*.t";
  / Check file exists
  if[()~key hsym`$file;
    -2"File not found: ",file;
    :(0;1;1)];
  parsed:$[isT;parseTFile file;parseQFile file];
  lines:parsed 0;
  tests:parsed 1;
  / Filter by function if --fn specified
  if[not filterFn~`;
    tests:tests where tests[`fn]=filterFn;
    if[0=count tests;
      :(0;0;0)]];  / No tests for this function in this file
  / Load dependencies
  $[isT;
    [r:loadDeps[file;lines];
     if[`fail~first r;
       (hsym`$(file,".failed"))0:enlist r 1;
       -2"Error: Failed to load dependencies for ",file,": ",r 1;
       :(0;1;1)]];
    [r:loadFile file;
     if[`fail~first r;
       (hsym`$(file,".failed"))0:enlist r 1;
       -2"Error: Failed to load ",file,": ",r 1;
       :(0;1;1)]]];
  results:runTests[file;tests;0b];
  if[(::)~results;:(0;1;1)];
  testSums:computeSummaries results;
  changed:results where results[`changeType]in`new`modified`error;
  newTests:results where results[`changeType]~'`new;
  failed:results where results[`changeType]in`modified`error;
  cf:$[0<count changed;writeCorrected[file;lines;results];""];
  autoMerged:0b;
  if[autoMergeNew&(0<count newTests)&0=count failed;
    if[0<count cf;
      cnt:read0 hsym`$cf;
      (hsym`$file)0:cnt;
      hdel hsym`$cf;
      autoMerged:1b;
      cf:""]];
  staleRemoved:"";
  if[0=count changed;
    corrPath:file,".corrected";
    if[not()~key hsym`$corrPath;
      hdel hsym`$corrPath;
      staleRemoved:corrPath]];
  / Output (single file mode still uses full output)
  $[junit;printJunit[file;testSums;results];
    json;printJson[file;testSums;failed;cf];
    batchdiffs;
      [tp:sum testSums[`passed];tf:sum testSums[`failed];tnew:sum testSums[`new];
       status:$[0=tf;"PASS";"FAIL"];
       suffix:$[autoMerged;" (auto-merged)";0<tnew;", ",string[tnew]," new";""];
       -1 status," ",file,": ",string[tp]," passed, ",string[tf]," failed",suffix;
       if[0<count cf;-1"  .corrected: ",cf]];
    errorsOnly;
      [tp:sum testSums[`passed];tf:sum testSums[`failed];
       if[0<count failed;
         $[listci;
           [i:0;while[i<count failed;-1 formatCiError[file;failed i];i:i+1]];
           [i:0;while[i<count failed;-1"  ",formatErrorLine[file;failed i];i:i+1]]]];
       -1 file,": ",string[tf]," error(s), ",string[tp]," passed"];
      [i:0;while[i<count changed;printDiff[file;changed i];i:i+1];
       if[0<count failed;printErrors[file;failed]];
       printSectionSummaries testSums;
       printSummary[file;testSums];
       if[autoMerged;-1"Auto-merged ",string[count newTests]," new test(s) in ",file];
       if[0<count cf;
         $[launchDiff[file;cf];
           -1"Opened diff tool for ",cf;
           -1"Wrote ",cf," (use 'git diff' or 'qdust promote' to review)"]];
       if[0<count staleRemoved;-1"Removed stale ",staleRemoved," (all tests pass)"]]];
  ec:ciExitCode testSums;
  tp:sum testSums[`passed];tf:sum testSums[`failed];
  (tp;tf;ec)}

/ Test multiple files - aggregates results
cmdTestMultiple:{[files]
  if[0=count files;
    -1"No test files found.";
    exit 0];
  totalPassed:0;totalFailed:0;anyFail:0b;
  -1"Running ",string[count files]," test file(s)...\n";
  i:0;
  while[i<count files;
    file:files i;
    / Use batch mode for multiple files
    oldBatch:batchdiffs;
    batchdiffs::1b;
    res:cmdTestSingle file;
    batchdiffs::oldBatch;
    totalPassed+:res 0;
    totalFailed+:res 1;
    if[res[2]>0;anyFail:1b];
    i:i+1];
  -1"\n=== Total ===";
  -1"  Files:  ",string count files;
  -1"  Passed: ",string totalPassed;
  -1"  Failed: ",string totalFailed;
  exit $[anyFail;1;0]}

/ Main test entry point - handles files, directories, and globs
cmdTest:{[path]
  / Check if it's a directory
  $[isDir path;
    [files:findTestFiles path;
     cmdTestMultiple files];
    / Check for glob pattern (*, ?, [], **)
    isGlob path;
    [files:expandGlob path;
     cmdTestMultiple files];
    / Single file - use direct implementation for full output
    cmdTestFile path]}

/ Test single file with full output (not batch mode)
cmdTestFile:{[file]
  isT:file like"*.t";
  / Check file exists
  if[()~key hsym`$file;
    -2"File not found: ",file;
    exit 1];
  parsed:$[isT;parseTFile file;parseQFile file];
  lines:parsed 0;
  tests:parsed 1;
  / Filter by function if --fn specified
  if[not filterFn~`;
    tests:tests where tests[`fn]=filterFn;
    if[0=count tests;
      -1"No tests found for function: ",string filterFn;
      exit 0]];
  / Load dependencies
  $[isT;
    [r:loadDeps[file;lines];
     if[`fail~first r;
       (hsym`$(file,".failed"))0:enlist r 1;
       -2"Error: Failed to load dependencies: ",r 1;
       exit 1]];
    [r:loadFile file;
     if[`fail~first r;
       (hsym`$(file,".failed"))0:enlist r 1;
       -2"Error: Failed to load ",file,": ",r 1;
       exit 1]]];
  results:runTests[file;tests;0b];
  if[(::)~results;exit 1];
  testSums:computeSummaries results;
  changed:results where results[`changeType]in`new`modified`error;
  newTests:results where results[`changeType]~'`new;
  failed:results where results[`changeType]in`modified`error;
  cf:$[0<count changed;writeCorrected[file;lines;results];""];
  autoMerged:0b;
  if[autoMergeNew&(0<count newTests)&0=count failed;
    if[0<count cf;
      cnt:read0 hsym`$cf;
      (hsym`$file)0:cnt;
      hdel hsym`$cf;
      autoMerged:1b;
      cf:""]];
  staleRemoved:"";
  if[0=count changed;
    corrPath:file,".corrected";
    if[not()~key hsym`$corrPath;
      hdel hsym`$corrPath;
      staleRemoved:corrPath]];
  $[junit;printJunit[file;testSums;results];
    json;printJson[file;testSums;failed;cf];
    batchdiffs;
      [tp:sum testSums[`passed];tf:sum testSums[`failed];tnew:sum testSums[`new];
       status:$[0=tf;"PASS";"FAIL"];
       suffix:$[autoMerged;" (auto-merged)";0<tnew;", ",string[tnew]," new";""];
       -1 status," ",file,": ",string[tp]," passed, ",string[tf]," failed",suffix;
       if[0<count cf;-1"  .corrected: ",cf]];
      [i:0;while[i<count changed;printDiff[file;changed i];i:i+1];
       if[0<count failed;printErrors[file;failed]];
       printSectionSummaries testSums;
       printSummary[file;testSums];
       if[autoMerged;-1"Auto-merged ",string[count newTests]," new test(s) in ",file];
       if[0<count cf;
         $[launchDiff[file;cf];
           -1"Opened diff tool for ",cf;
           -1"Wrote ",cf," (use 'git diff' or 'qdust promote' to review)"]];
       if[0<count staleRemoved;-1"Removed stale ",staleRemoved," (all tests pass)"]]];
  exit ciExitCode testSums}

cmdDiff:{[file]
  / Show diff between file and .corrected
  corr:file,".corrected";
  if[()~key hsym`$corr;
    -1"Tests passed (or haven't been run). No .corrected file present.";
    exit 0];
  / Try QDUST_DIFF env var first
  if[launchDiff[file;corr];exit 0];
  / Fall back to system diff
  -1"diff ",file," ",corr;
  -1"";
  system"diff \"",file,"\" \"",corr,"\" || true";
  exit 0}

cmdPromote:{[file]
  corr:file,".corrected";
  $[()~key hsym`$corr;
    [-2"No .corrected file found for ",file;exit 1];
    [cnt:read0 hsym`$corr;
     (hsym`$file)0:cnt;
     hdel hsym`$corr;
     -1"Promoted ",file;
     exit 0]]}

help:{
  -1"qdust - Q/K Expect Test Runner";
  -1"";
  -1"Usage:";
  -1"  q qdust.q test <file.q>     Run tests in file";
  -1"  q qdust.q test <dir>        Run all tests in directory (recursive)";
  -1"  q qdust.q test .            Run all tests in current directory";
  -1"  q qdust.q test \"*.q\"        Run tests matching glob pattern";
  -1"  q qdust.q diff <file.q>     Show diff between file and .corrected";
  -1"  q qdust.q promote <file.q>  Accept .corrected as new expected";
  -1"";
  -1"Options:";
  -1"  --fn <name>                Run only tests for specified function";
  -1"  --init <file>              Load init file (sets up customloader)";
  -1"  --json                     Output in JSON format";
  -1"  --junit                    Output in JUnit XML format (for CI)";
  -1"  --errors-only              Show only errors, not full output";
  -1"  --listci                   CI-clickable error format";
  -1"  --auto-merge-new           Auto-promote if only new tests (no changes)";
  -1"  --no-auto-merge-new        Require manual review for all (default)";
  -1"";
  -1"Directives (paste-safe comments):";
  -1"  /@fn:label                 Link following tests to label (any text)";
  -1"  /@fn:                      Reset (no label)";
  -1"  /@ci:required              Tests must pass in CI";
  -1"  /@ci:optional              CI failures are warnings";
  -1"  /@ci:skip                  Skip in CI";
  -1"";
  -1"Test formats (.q/.k files):";
  -1"  /// 1+1 -> 2               Comment with -> is a test";
  -1"  // 1+1 -> 2                Double slash also works";
  -1"  add:{x+y}                  Function def sets implicit context";
  -1"  /// add[1;2] -> 3          Test linked to 'add' implicitly";
  -1"";
  -1"Test formats (.t files):";
  -1"  /@fn:myFunc                Link following tests to myFunc";
  -1"  q)1+1 -> 2                 REPL inline (result on same line)";
  -1"  q)til 5                    REPL block (result on next lines)";
  -1"  0 1 2 3 4";
  -1"  1+1 -> 2                   Inline test (no prefix needed)";
  -1"";
  -1"Loading (.t files only):";
  -1"  Paired file: foo.t auto-loads foo.q if it exists";
  -1"  / @load lib.q              Explicit dependency";
  -1"";
  -1"Environment:";
  -1"  QDUST_INIT                  Init file path (alternative to --init)";
  -1"  QDUST_DIFF                  Diff tool command (e.g. \"code --diff\")";
  -1"";
  -1"Notes:";
  -1"  Per-expression timeout is not supported in pure Q.";
  -1"  For hanging tests, wrap qdust with: timeout 60 q qdust.q test file.q";
  exit 0}

/ ============================================================================
/ Init Loading
/ ============================================================================

/ Load init file (sets up customloader, etc.)
loadInit:{
  / Check --init arg first, then QDUST_INIT env var
  if[0<count initFile;
    if[not()~key hsym`$initFile;
      @[system;"l ",initFile;{-2"Warning: Failed to load init file: ",x}];
      :()];
    -2"Warning: Init file not found: ",initFile;
    :()];
  / Check env var
  envInit:@[getenv;"QDUST_INIT";{""}];
  if[0<count envInit;
    if[not()~key hsym`$envInit;
      @[system;"l ",envInit;{-2"Warning: Failed to load init file: ",x}];
      :()];
    -2"Warning: QDUST_INIT file not found: ",envInit]}

/ ============================================================================
/ Main
/ ============================================================================

main:{
  args:.z.x;
  / Parse flags (including --init which needs value)
  i:0;
  while[i<count args;
    $[args[i]~"--json";json::1b;
      args[i]~"--junit";junit::1b;
      args[i]~"--batchdiffs";batchdiffs::1b;
      args[i]~"--errors-only";errorsOnly::1b;
      args[i]~"--listci";listci::1b;
      args[i]~"--auto-merge-new";autoMergeNew::1b;
      args[i]~"--no-auto-merge-new";autoMergeNew::0b;
      args[i]in("-v";"--verbose");verbose::1b;
      (args[i]~"--init")&(i+1)<count args;[initFile::args i+1;i:i+1];
      (args[i]~"--fn")&(i+1)<count args;[filterFn::`$args i+1;i:i+1];
      ()];
    i:i+1];
  / Load init file (may override customloader)
  loadInit[];
  / Remove flags and their values
  args:args where not(args like"-*")|(args like"--*");
  cmd:$[0<count args;args 0;""];
  file:$[1<count args;args 1;""];
  $[cmd~"test";$[0<count file;cmdTest file;help[]];
    cmd~"diff";$[0<count file;cmdDiff file;help[]];
    cmd~"promote";$[0<count file;cmdPromote file;help[]];
    help[]]}

\d .

/ Run if invoked from command line
if[0<count .z.x;.qd.main[]]
