/ qdust.q - Q/K Expect Test Runner
/ dune-style expect tests for Q/K with diff/promote workflow
/ .
/ Single-file test runner + multi-file orchestrator in one file.
/ Use -one flag for subprocess isolation (internal).
/ .
/ Usage:
/   q qdust.q test file.q              Run tests in file
/   q qdust.q test <dir>               Run all tests in directory
/   q qdust.q test <pattern>           Run tests matching pattern (recursive)
/   q qdust.q promote <dir|file>       Accept .corrected files
/   q qdust.q check [dir]              Fail if .corrected files exist (CI)
/   q qdust.q -json test <target>     Output in JSON format

\d .qd

/ ============================================================================
/ Configuration
/ ============================================================================

verbose:0b
json:0b
junit:0b
batchdiffs:0b     / Batch mode: generate .corrected but don't print diffs
autoMergeNew:0b   / Auto-promote if only new tests (no modified/errors)
errorsOnly:0b     / Only show errors, not full output
listci:0b         / CI-clickable error format
filterFn:`       / Filter tests by function name (` = no filter)

/ External diff tool via QDUST_DIFF env var (single-file mode)
oneLaunchDiff:{[orig;corrected]
  d:getenv`QDUST_DIFF;
  if[0<count d;system d," \"",orig,"\" \"",corrected,"\" &";:1b];
  0b}

/ Custom loader - override in init file for custom loading schemes
customloader:{[file] system"l ",file}

/ Init file path (set via -init or QDUST_INIT)
initFile:""

/ Orchestrator-only settings
diffMode:`console       / `none`console`ide
launchDiffEnabled:1b    / Launch IDE diff tool for each file with diffs
rerunAfterDiff:0b       / Rerun tests after diff tool closes

/ Report settings
reportFile:""           / Path to report file (auto or -report-file)
noReport:0b             / Skip report read/write (-no-report)
minTests:0N             / -min-tests gate (null = disabled)
minPass:100             / -min-pass gate (default 100%)
minPassPct:1b           / 1b if minPass is a percentage (e.g. -min-pass 90%)
testCategory:`preflight / `preflight (default), `integration, or `all

/ IPC mode settings
ipcMode:1b              / IPC mode default on; -noipc to disable
ipcTimeout:5            / -timeout: per-expression timeout in seconds (0 = none)

/ Debug mode settings
debugMode:0b            / -debug: enable \e 1, raw value for unexpected errors
debugExpected:""        / set by runTests before each evalExpr call in debug mode

/ Feature detection: .Q.trp/.Q.sbt available from ~3.6
hasTrp:`trp in key `.Q
/ Trap with backtrace when available, plain @[;;] fallback
trp:{[f;x;h] $[hasTrp;.Q.trp[f;x;h];@[f;x;{[h;e] h[e;()]}[h]]]}
/ Format backtrace when available, empty string fallback
sbt:{$[`sbt in key `.Q;.Q.sbt x;""]}

/ Path to this script (cached at load time for subprocess spawning)
qdustPath:string .z.f

/ ============================================================================
/ Path Utilities
/ ============================================================================

/ Extract directory from file path: "/a/b/c.q" -> "/a/b", "c.q" -> ""
dirOf:{[path]
  s:$[(0<count path)&"/"=last path;-1_path;path];
  i:last where s="/";
  $[null i;"";i#s]}

/ Get parent directory: "/a/b" -> "/a", "/" -> ""
parentDir:{[dir]
  if[(0=count dir)|dir~"/";:""];
  dirOf dir}

/ Check if file/dir exists at path
pathExists:{[path] not()~key hsym`$path}

/ ============================================================================
/ Q Environment Discovery
/ ============================================================================

/ Discover the Q executable running this process
qSelf:{
  / Linux: /proc/self/exe
  p:@[{first system"readlink /proc/self/exe 2>/dev/null"};`;""];
  if[0<count p;:p];
  / macOS: lsof on PID
  p:@[{first system"lsof -p ",string[.z.i]," -Fn 2>/dev/null | grep \"^n.*\" | grep \"/q$\" | cut -c2-"};`;""];
  if[0<count p;:p];
  / Fallback: derive from QHOME
  h:@[getenv;"QHOME";{""}];
  if[0<count h;
    os:@[{string .z.o};`;""];
    if[0<count os;
      p:$["/"=last h;h;h,"/"],os,"/q";
      if[pathExists p;:p]]];
  / Last resort
  "q"}

/ Resolve Q executable path
/ Precedence: .qd.q (QINIT) > QDUST_Q env var > current process binary
qExec:{
  if[`q in key `.qd;e:string .qd.q;if[0<count e;:e]];
  e:@[getenv;"QDUST_Q";{""}];
  if[0<count e;:e];
  qSelf[]}

/ Q flags to pass before the script (e.g. "-debug", "-s 4")
/ Precedence: .qd.qflags (set via QINIT) > QDUST_QFLAGS env var > ""
qFlags:{
  if[`qflags in key `.qd;f:string .qd.qflags;if[0<count f;:f," "]];
  f:@[getenv;"QDUST_QFLAGS";{""}];
  if[0<count f;:f," "];
  ""}

/ Discover QHOME directory (where q.k lives)
/ Precedence: .qd.qhome (QINIT) > QHOME env var > walk up from binary (q.k probe)
qHome:{
  if[`qhome in key `.qd;h:string .qd.qhome;if[0<count h;:h]];
  h:@[getenv;"QHOME";{""}];
  if[0<count h;:h];
  / Walk up from binary looking for q.k (up to 3 levels)
  s:qSelf[];
  if[not s~"q";
    d:dirOf s;n:0;
    while[(0<count d)&n<3;
      dd:$["/"=last d;d;d,"/"];
      if[pathExists dd,"q.k";:d];
      d:parentDir d;n:n+1]];
  ""}

/ Discover QLIC directory (where kc.lic or k4.lic lives)
/ Precedence: .qd.qlic (QINIT) > QLIC env var > walk up from QHOME > walk up from binary
qLic:{
  if[`qlic in key `.qd;l:string .qd.qlic;if[0<count l;:l]];
  l:@[getenv;"QLIC";{""}];
  if[0<count l;:l];
  / Walk up from QHOME (up to 2 levels)
  h:qHome[];
  if[0<count h;
    d:h;n:0;
    while[(0<count d)&n<2;
      dd:$["/"=last d;d;d,"/"];
      if[(pathExists dd,"kc.lic")|(pathExists dd,"k4.lic");:d];
      d:parentDir d;n:n+1]];
  / Walk up from binary (up to 3 levels)
  s:qSelf[];
  if[not s~"q";
    d:dirOf s;n:0;
    while[(0<count d)&n<3;
      dd:$["/"=last d;d;d,"/"];
      if[(pathExists dd,"kc.lic")|(pathExists dd,"k4.lic");:d];
      d:parentDir d;n:n+1]];
  ""}

/ Build environment prefix for subprocess commands
/ Returns e.g. "QHOME=/opt/kdb; QLIC=/opt/kdb; " or ""
qEnvPrefix:{
  p:"";
  h:qHome[];
  if[0<count h;p:p,"QHOME=\"",h,"\"; "];
  l:qLic[];
  if[0<count l;p:p,"QLIC=\"",l,"\"; "];
  p}

/ ============================================================================
/ IPC Utilities (for IPC mode)
/ ============================================================================

/ Port range for IPC workers (default 10000..65535, override via QDUST_PORTS=min..max)
ipcPortRange:{
  env:@[getenv;"QDUST_PORTS";{""}];
  r:$[0<count env;
    [p:"J"$".."vs env; p[0],p[1]];
    10000 65535];
  r[0]:r[0]|10000;
  r[1]:r[1]&65535;
  r}[]

/ Check if a port is available (try to connect; failure means free)
ipcPortFree:{[port]
  h:@[hopen;`$":localhost:",string port;0Ni];
  $[null h;1b;[hclose h;0b]]}

/ Pick a random available port in the configured range
ipcRandomPort:{
  lo:ipcPortRange 0;hi:ipcPortRange 1;
  n:0;
  while[n<25;
    p:lo+rand 1+hi-lo;
    if[ipcPortFree p;:p];
    n:n+1];
  '"No free port found in ",string[lo],"..",string hi}

/ Start a worker Q process on a given port, return PID
ipcStartWorker:{[port]
  shf:"/tmp/qdust_wk_",string[port],".sh";
  pidf:"/tmp/qdust_wk_",string[port],".pid";
  targ:$[ipcTimeout>0;" -timeout ",string ipcTimeout;""];
  cmd:qEnvPrefix[],qExec[]," ",qFlags[],qdustPath," -worker",targ," -p ",string[port]," < /dev/null > /dev/null 2>&1 &";
  (hsym`$shf)0:enlist cmd,"\necho $! > ",pidf;
  system"bash ",shf;
  system"rm -f ",shf;
  / Wait for PID file
  n:0;
  while[(()~key hsym`$pidf)&n<20;system"sleep 0.1";n:n+1];
  pid:"I"$first read0 hsym`$pidf;
  system"rm -f ",pidf;
  pid}

/ Connect to worker with retry/backoff
ipcConnect:{[port]
  n:0;
  while[n<30;
    h:@[hopen;`$":localhost:",string port;0Ni];
    if[not null h;:h];
    system"sleep 0.1";
    n:n+1];
  '"Failed to connect to worker on port ",string port}

/ ============================================================================
/ Project Root Detection
/ ============================================================================

/ Project root path (set via -root or auto-detected from .qd/.git)
projectRoot:""

/ Find project root by walking up from dir
/ Precedence: .qd file > .git directory
/ Returns path with trailing / or "" if not found
findRoot:{[dir]
  d:dir;
  while[0<count d;
    if[pathExists d,"/.qd";:d,"/"];
    d:parentDir d];
  d:dir;
  while[0<count d;
    if[pathExists d,"/.git";:d,"/"];
    d:parentDir d];
  ""}

/ Detect and cache project root from test file path
detectRoot:{[file]
  if[0<count projectRoot;:()];
  fdir:$["/"=first file;dirOf file;dirOf(first system"pwd"),"/",file];
  projectRoot::findRoot fdir;
  if[verbose&0<count projectRoot;-2"Project root: ",projectRoot]}

/ ============================================================================
/ Prefix Substitution
/ ============================================================================

testDirNames:("tests";"test";"tst")

/ Find test dir component in path segments, return index or -1
findTestDir:{[parts]
  i:count[parts]-1;
  while[i>=0;
    if[parts[i] in testDirNames;:i];
    i:i-1];
  -1}

/ Given a test file path, resolve source file via prefix substitution
/ Finds test/tests/tst component, replaces with src/ (try first) or strips (try second)
/ Returns source .q path or "" if not found
resolveSource:{[file]
  parts:"/"vs file;
  tdi:findTestDir parts;
  if[tdi<0;:""];
  / Split: prefix (before test dir), rest (after test dir)
  prefix:"/"sv tdi#parts;
  if[0<count prefix;prefix:prefix,"/"];
  rest:(tdi+1)_parts;
  / Build candidate relative paths (deepest first)
  stem:(-2_last rest);
  dirParts:-1_rest;
  paths:();
  if[0<count dirParts;
    paths:paths,enlist("/"sv dirParts),"/",stem,".q";
    i:count[dirParts]-1;
    while[i>=0;
      paths:paths,enlist("/"sv (i+1)#dirParts),".q";
      i:i-1]];
  if[0=count dirParts;
    paths:enlist stem,".q"];
  / For each candidate, try src/ first, then without
  j:0;
  while[j<count paths;
    if[pathExists prefix,"src/",paths j;:prefix,"src/",paths j];
    if[pathExists prefix,paths j;:prefix,paths j];
    j:j+1];
  ""}

/ Resolve @load path relative to project root
resolvePath:{[path]
  if[0=count projectRoot;:path];
  if["/"=first path;:path];
  projectRoot,path}

/ ============================================================================
/ Argument Parsing
/ ============================================================================

/ Parse command-line arguments into flags dict and positional args
/ valFlags: list of flag strings that consume the next arg as value
/ args: list of arg strings (.z.x)
/ Returns (dict;list) - symbol-keyed flag dict and positional arg list
/ All values stored as strings (boolean flags get "") so dict stays generic
parseArgs:{[valFlags;args]
  d:(`$())!();
  pos:();
  i:0;
  while[i<count args;
    a:args i;
    $[(any valFlags~\:a)&(i+1)<count args;
      [d[`$a]:args i+1;i:i+2];
      (0<count a)&"-"=a 0;
      [d[`$a]:"";i:i+1];
      [pos:pos,enlist a;i:i+1]]];
  (d;pos)}

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

/ Detect file category from directives. Scans for / @integration or / @preflight.
/ Returns `integration or `preflight (default).
detectCategory:{[file]
  lines:@[read0;hsym`$file;()];
  if[0=count lines;:`preflight];
  / Scan first 50 lines (directives should be near top)
  n:min(count lines;50);
  i:0;
  while[i<n;
    t:trim lines i;
    if[t~"/ @integration";:`integration];
    if[t~"/ @preflight";:`preflight];
    i:i+1];
  `preflight}

/ Parse .q file - returns (lines;tests)
parseQFile:{[file]
  lines:read0 hsym`$file;
  n:count lines;
  tests:1_enlist mkTest(0;"";"";0;`;defaultSection;`q;0b;"";`);
  sec:defaultSection;
  curFn:`;
  i:0;
  while[i<n;
    line:lines i;
    t:trim line;
    ln:i+1;
    fnDef:parseFnDef line;
    $[not fnDef~`;
      [curFn:fnDef;i:i+1];
      isSection t;
      [sec:`name`line`ci!(parseSection t;ln;`default);i:i+1];
      isCiTag t;
      [sec:@[sec;`ci;:;parseCiTag t];i:i+1];
      isFnTag t;
      [curFn:parseFnTag t;i:i+1];
      isTestLine t;
      [content:stripSlashes t;
       pfx:getPrefix t;
       $[isReplContent content;
         [mode:$[content[0]="k";`k;`q];
          r:parseReplLine[collectQReplExpected;lines;i;2_content;sec;mode;pfx;curFn];
          tests:tests,enlist r 0;i:r 1];
         [arrow:splitArrow content;
          if[0<count arrow;
            tests:tests,enlist mkTest(ln;arrow 0;arrow 1;i;`inline;sec;`q;0b;pfx;curFn)];
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

/ Build a test dict
mkTest:{`line`expr`expected`endLine`format`section`mode`isSilent`prefix`fn!x}

/ Parse a REPL test line - returns (test;newIndex)
/ rest is the expression (after q)/k) prefix), collect gathers expected lines
parseReplLine:{[collect;lines;i;rest;sec;mode;pfx;curFn]
  ln:i+1;
  arrow:splitArrow rest;
  $[0<count arrow;
    (mkTest(ln;arrow 0;arrow 1;i;`inline;sec;mode;0b;pfx;curFn);i+1);
    isSilentExpr[rest];
    (mkTest(ln;rest;"";i;`silent;sec;mode;1b;pfx;curFn);i+1);
    [r:collect[lines;i+1]; expLines:r 0;ni:r 1;
     (mkTest(ln;rest;"\n"sv expLines;ni;`repl;sec;mode;0b;pfx;curFn);ni)]]}

/ Parse .t file (REPL style + inline) - returns (lines;tests)
parseTFile:{[file]
  lines:read0 hsym`$file;
  n:count lines;
  tests:1_enlist mkTest(0;"";"";0;`;defaultSection;`q;0b;"";`);
  sec:defaultSection;
  curFn:`;
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
       r:parseReplLine[collectReplExpected;lines;i;2_line;sec;mode;"";curFn];
       tests:tests,enlist r 0;i:r 1];
      isInlineTest line;
      [arrow:splitArrow line;
       if[0<count arrow;
         tests:tests,enlist mkTest(ln;arrow 0;arrow 1;i;`inline;sec;`q;0b;"";curFn)];
       i:i+1];
      i:i+1]];
  (lines;tests)}

/ ============================================================================
/ Execution
/ ============================================================================

/ Evaluate expression with format choice and backtrace capture
/ pretty=1b uses .Q.s (multiline tables), pretty=0b uses -3! (compact)
/ Returns 3-tuple: (formatted_result; error_string; backtrace_string)
evalExpr:{[expr;pretty]
  fmt:$[pretty;s1Pretty;s1];
  trp[{[f;e] r:value e; (f r;"";"")}[fmt];expr;{[err;bt] ("";"'",err;sbt bt)}]}

loadFile:{[file]
  @[{customloader x;`ok};file;{(`fail;x)}]}

/ Parse @load directives from file lines
/ Handles: / @load, // @load, /// @load, with variable spacing
/ Returns list of files to load
parseLoadDirectives:{[lines]
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
/ Precedence: 1. @load  2. Colocation  3. Prefix substitution  4. Standalone
loadDeps:{[file;lines]
  / 1. Load paired file first (for .t files)
  paired:getPairedFile file;
  if[0<count paired;
    r:loadFile paired;
    if[`fail~first r;:r]];
  / 2. Load @load directives (resolved relative to project root)
  deps:parseLoadDirectives lines;
  i:0;
  while[i<count deps;
    r:loadFile resolvePath deps i;
    if[`fail~first r;:r];
    i:i+1];
  / 3. If no paired file and no @load, try prefix substitution
  if[(0=count paired)&(0=count deps);
    src:resolveSource file;
    if[0<count src;
      if[verbose;-2"Prefix substitution: ",file," -> ",src];
      r:loadFile src;
      if[`fail~first r;:r]]];
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
      -2"Error: Failed to load ",file,": ",r 1;
      :(::)]];
  results:();
  i:0;
  while[i<count tests;
    t:tests i;
    isSilent:$[`isSilent in key t;t[`isSilent];0b];
    / inline uses -3! (compact), repl/block uses .Q.s (pretty)
    pretty:t[`format]in`repl`block;
    t0:.z.P;
    $[`skip~t[`section][`ci];
      results:results,enlist t,`actual`error`backtrace`passed`skipped`changeType`duration_ms!("";"";"";1b;1b;`skip;0);
      isSilent;
      [if[debugMode;debugExpected::t`expected];
       r:evalExpr[t[`expr];0b];
       / Semicolon statement: pass if no error, abort file if error
       if[0<count r 1;
         :(`silentErr`expr`line`error`backtrace!(1b;t`expr;t`line;r 1;r 2))];
       durMs:(`long$.z.P-t0)div 1000000;
       results:results,enlist t,`actual`error`backtrace`passed`skipped`changeType`duration_ms!(r 0;r 1;r 2;1b;0b;`silent;durMs)];
      [if[debugMode;debugExpected::t`expected];
       r:evalExpr[t[`expr];pretty];
       changeType:getChangeType[t;r 0;r 1];
       / New tests always "pass" (we're capturing the result)
       passed:$[changeType in`new`unchanged;1b;0b];
       durMs:(`long$.z.P-t0)div 1000000;
       results:results,enlist t,`actual`error`backtrace`passed`skipped`changeType`duration_ms!(r 0;r 1;r 2;passed;0b;changeType;durMs)]];
    i:i+1];
  results}

/ ============================================================================
/ Section Summaries
/ ============================================================================

computeSummaries:{[results]
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
  f:md+er;
  enlist `section`total`passed`failed`skipped`new`modified`errors`silent!(firstSec;`long$n;p;f;s;nw;md;er;st)}

/ Process test results: summaries, corrected file, auto-merge, stale removal
/ Returns (testSums;cf;autoMerged;staleRemoved)
processResults:{[file;lines;results]
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
  (testSums;cf;autoMerged;staleRemoved)}

ciStr:{$[x~`required;"required";x~`optional;"optional";x~`skip;"skip";""]}

/ Check if runTests result is a silent statement error
isSilentErr:{$[99h=type x;`silentErr in key x;0b]}

/ Format silent error for output (stderr lines)
printSilentErr:{[file;err]
  -2"Error in setup statement: ",file,":",string[err`line];
  -2"  Expression: ",err`expr;
  -2"  Error:      ",err`error;
  if[0<count err`backtrace;-2"  Backtrace:\n",err`backtrace]}

/ ============================================================================
/ Single-File Output
/ ============================================================================

printDiff:{[file;r]
  ci:$[`default~r[`section][`ci];"";" [ci:",ciStr[r[`section][`ci]],"]"];
  secname:r[`section][`name];
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
     $[0<count r[`error];-1"  Error:      ",r[`error];-1"  Actual:     ",r[`actual]];
     if[(`backtrace in key r)&0<count r[`backtrace];-1"  Backtrace:\n",r[`backtrace]]]];}

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

onePrintSummary:{[file;summaries]
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
         [act:$[0<count r[`error];r[`error];r[`actual]];
          $["\n"in act;
            out:out,enlist[cpfx,r[`expr]],cpfx,/:"\n"vs act;
            out:out,enlist cpfx,r[`expr]," -> ",act];
          i:i+1];
         `block~r[`format];
         [act:$[0<count r[`error];r[`error];r[`actual]];
          i2:r[`endLine];
          out:out,enlist[lines i],cpfx,/:"\n"vs act;
          i:i2];
         `repl~r[`format];
         [rpfx:$[`k~r[`mode];"k)";"q)"];
          act:$[0<count r[`error];r[`error];r[`actual]];
          i2:r[`endLine];
          out:out,enlist[cpfx,rpfx,r[`expr]],cpfx,/:"\n"vs act;
          i:i2];
         `silent~r[`format];
         [rpfx:$[`k~r[`mode];"k)";"q)"];
          / Silent errors abort the file in runTests — only passing statements reach here
          out:out,enlist[cpfx,rpfx,r[`expr]];
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
/ Single-File Commands
/ ============================================================================

/ Lightweight file content hash (sum of byte values) for change detection
fileHash:{[f] sum "i"$raze read0 hsym`$f}

/ Load, parse, and prepare a file for testing
/ Returns (tests;lines;fhash;error) — error is "" on success
prepareFile:{[file]
  isT:file like"*.t";
  if[()~key hsym`$file;
    :(();();0;"File not found: ",file)];
  fhash:fileHash file;
  detectRoot file;
  parsed:$[isT;parseTFile file;parseQFile file];
  lines:parsed 0;
  tests:parsed 1;
  / Load dependencies
  err:$[isT;
    [r:loadDeps[file;lines];
     $[`fail~first r;r 1;""]];
    [r:loadFile file;
     $[`fail~first r;r 1;""]]];
  if[0<count err;:(();lines;fhash;err)];
  (tests;lines;fhash;"")}

/ Test a single file - returns (passed;failed;exitCode;durMs;fhash)
oneCmdTestSingle:{[file]
  fileStart:.z.P;
  pf:prepareFile file;
  tests:pf 0;lines:pf 1;fhash:pf 2;err:pf 3;
  if[0<count err;
    -2"Error: ",err;
    :(0;1;1;0;fhash)];
  / Filter by function if -fn specified
  if[not filterFn~`;
    tests:tests where tests[`fn]=filterFn;
    if[0=count tests;
      :(0;0;0;0;fhash)]];
  if[0=count tests;
    fileDurMs:(`long$.z.P-fileStart)div 1000000;
    :(0;0;0;fileDurMs;fhash)];
  results:runTests[file;tests;0b];
  if[(::)~results;
    -1"FAIL ",file,": 0 passed, 1 failed [0ms hash:",string[fhash],"]";
    :(0;1;1;0;fhash)];
  if[isSilentErr results;
    -1"FAIL ",file,": 0 passed, 1 failed [0ms hash:",string[fhash],"]";
    printSilentErr[file;results];
    :(0;1;1;0;fhash)];
  pr:processResults[file;lines;results];
  testSums:pr 0;cf:pr 1;autoMerged:pr 2;staleRemoved:pr 3;
  changed:results where results[`changeType]in`new`modified`error;
  failed:results where results[`changeType]in`modified`error;
  fileDurMs:(`long$.z.P-fileStart)div 1000000;
  / Output
  $[junit;printJunit[file;testSums;results];
    json;printJson[file;testSums;failed;cf];
    batchdiffs;
      [tp:sum testSums[`passed];tf:sum testSums[`failed];tnew:sum testSums[`new];
       status:$[0=tf;"PASS";"FAIL"];
       suffix:$[autoMerged;" (auto-merged)";0<tnew;", ",string[tnew]," new";""];
       -1 status," ",file,": ",string[tp]," passed, ",string[tf]," failed",suffix," [",string[fileDurMs],"ms hash:",string[fhash],"]";
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
       onePrintSummary[file;testSums];
       if[autoMerged;-1"Auto-merged ",string[sum testSums[`new]]," new test(s) in ",file];
       if[0<count cf;
         $[oneLaunchDiff[file;cf];
           -1"Opened diff tool for ",cf;
           -1"Wrote ",cf," (use 'git diff' or 'qdust promote' to review)"]];
       if[0<count staleRemoved;-1"Removed stale ",staleRemoved," (all tests pass)"]]];
  ec:ciExitCode testSums;
  tp:sum testSums[`passed];tf:sum testSums[`failed];
  (tp;tf;ec;fileDurMs;fhash)}

/ Test multiple files - aggregates results
oneCmdTestMultiple:{[files]
  if[0=count files;
    -1"No test files found.";
    exit 0];
  totalPassed:0;totalFailed:0;anyFail:0b;
  -1"Running ",string[count files]," test file(s)...\n";
  i:0;
  while[i<count files;
    file:files i;
    oldBatch:batchdiffs;
    batchdiffs::1b;
    res:oneCmdTestSingle file;
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

/ Single-file test entry point - handles files, directories, and globs
oneCmdTest:{[path]
  $[isDir path;
    [files:findTestFiles path;
     oneCmdTestMultiple files];
    isGlob path;
    [files:expandGlob path;
     oneCmdTestMultiple files];
    oneCmdTestFile path]}

/ Test single file with full output (not batch mode)
oneCmdTestFile:{[file]
  pf:prepareFile file;
  tests:pf 0;lines:pf 1;err:pf 3;
  if[0<count err;
    -2"Error: ",err;
    exit 1];
  / Filter by function if -fn specified
  if[not filterFn~`;
    tests:tests where tests[`fn]=filterFn;
    if[0=count tests;
      -1"No tests found for function: ",string filterFn;
      exit 0]];
  if[0=count tests;
    -1"PASS ",file,": 0 passed, 0 failed [0ms hash:",string[pf 2],"]";
    exit 0];
  results:runTests[file;tests;0b];
  if[(::)~results;
    -1"FAIL ",file,": 0 passed, 1 failed [0ms hash:0]";
    exit 1];
  if[isSilentErr results;
    -1"FAIL ",file,": 0 passed, 1 failed [0ms hash:",string[pf 2],"]";
    printSilentErr[file;results];
    exit 1];
  pr:processResults[file;lines;results];
  testSums:pr 0;cf:pr 1;autoMerged:pr 2;staleRemoved:pr 3;
  changed:results where results[`changeType]in`new`modified`error;
  failed:results where results[`changeType]in`modified`error;
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
       onePrintSummary[file;testSums];
       if[autoMerged;-1"Auto-merged ",string[sum testSums[`new]]," new test(s) in ",file];
       if[0<count cf;
         $[oneLaunchDiff[file;cf];
           -1"Opened diff tool for ",cf;
           -1"Wrote ",cf," (use 'git diff' or 'qdust promote' to review)"]];
       if[0<count staleRemoved;-1"Removed stale ",staleRemoved," (all tests pass)"]]];
  exit ciExitCode testSums}

oneCmdDiff:{[file]
  corr:file,".corrected";
  if[()~key hsym`$corr;
    -1"Tests passed (or haven't been run). No .corrected file present.";
    exit 0];
  if[oneLaunchDiff[file;corr];exit 0];
  -1"diff ",file," ",corr;
  -1"";
  system"diff \"",file,"\" \"",corr,"\" || true";
  exit 0}

oneCmdPromote:{[file]
  corr:file,".corrected";
  $[()~key hsym`$corr;
    [-2"No .corrected file found for ",file;exit 1];
    [cnt:read0 hsym`$corr;
     (hsym`$file)0:cnt;
     hdel hsym`$corr;
     -1"Promoted ",file;
     exit 0]]}

oneHelp:{
  -1"qdust - Q/K Expect Test Runner (single-file mode)";
  -1"";
  -1"Usage:";
  -1"  q qdust.q -one test <file.q>      Run tests in file";
  -1"  q qdust.q -one test <dir>         Run all tests in directory";
  -1"  q qdust.q -one diff <file.q>      Show diff between file and .corrected";
  -1"  q qdust.q -one promote <file.q>   Accept .corrected as new expected";
  -1"";
  -1"Options:";
  -1"  -fn <name>                 Run only tests for specified function";
  -1"  -init <file>               Load init file (sets up customloader)";
  -1"  -root <path>               Project root (auto-detected from .qd/.git)";
  -1"  -json                      Output in JSON format";
  -1"  -junit                     Output in JUnit XML format (for CI)";
  -1"  -errors-only               Show only errors, not full output";
  -1"  -listci                    CI-clickable error format";
  -1"  -auto-merge-new            Auto-promote if only new tests (no changes)";
  -1"  -no-auto-merge-new         Require manual review for all (default)";
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
  -1"  Prefix substitution:       tests/x.t tries src/x.q then x.q";
  -1"  Recognized test dirs:      tests/ test/ tst/";
  -1"";
  -1"Environment:";
  -1"  QDUST_INIT                  Init file path (alternative to -init)";
  -1"  QDUST_DIFF                  Diff tool command (e.g. \"code --diff\")";
  exit 0}

/ ============================================================================
/ Init Loading
/ ============================================================================

loadInit:{
  if[0<count initFile;
    if[not()~key hsym`$initFile;
      @[system;"l ",initFile;{-2"Warning: Failed to load init file: ",x}];
      :()];
    -2"Warning: Init file not found: ",initFile;
    :()];
  envInit:@[getenv;"QDUST_INIT";{""}];
  if[0<count envInit;
    if[not()~key hsym`$envInit;
      @[system;"l ",envInit;{-2"Warning: Failed to load init file: ",x}];
      :()];
    -2"Warning: QDUST_INIT file not found: ",envInit]}

/ ============================================================================
/ Single-File Main
/ ============================================================================

oneMain:{
  r:parseArgs[("-init";"-root";"-fn");.z.x];
  d:r 0;pos:r 1;
  if[(`$"-json")in key d;json::1b];
  if[(`$"-junit")in key d;junit::1b];
  if[(`$"-batchdiffs")in key d;batchdiffs::1b];
  if[(`$"-errors-only")in key d;errorsOnly::1b];
  if[(`$"-listci")in key d;listci::1b];
  if[(`$"-auto-merge-new")in key d;autoMergeNew::1b];
  if[(`$"-no-auto-merge-new")in key d;autoMergeNew::0b];
  if[any(`$"-v";`$"-verbose")in key d;verbose::1b];
  if[(`$"-init")in key d;initFile::d`$"-init"];
  if[(`$"-root")in key d;projectRoot::d`$"-root"];
  if[(`$"-fn")in key d;filterFn::`$d`$"-fn"];
  loadInit[];
  cmd:$[0<count pos;pos 0;""];
  file:$[1<count pos;pos 1;""];
  $[cmd~"test";$[0<count file;oneCmdTest file;oneHelp[]];
    cmd~"diff";$[0<count file;oneCmdDiff file;oneHelp[]];
    cmd~"promote";$[0<count file;oneCmdPromote file;oneHelp[]];
    oneHelp[]]}

/ ============================================================================
/ Debug Mode (-debug)
/ ============================================================================

debugHelp:{
  -1"qdust - Debug Mode";
  -1"";
  -1"Usage:";
  -1"  q qdust.q -debug test <file>        Debug single file";
  -1"  q qdust.q -debug test <dir>         Debug all files in directory";
  -1"  q qdust.q -debug test <pattern>     Debug files matching glob";
  -1"";
  -1"Errors will drop into Q's q)) debugger prompt.";
  -1"Expected errors (tests with ' in expected output) are caught normally.";
  -1"";
  -1"For multiple files, a bash script is generated and executed.";
  -1"Each file runs in its own Q process with the terminal attached.";
  -1"";
  -1"Options:";
  -1"  -fn <name>        Run only tests for named function";
  -1"  -filter <pat>     Filter files by name";
  -1"  -init <file>      Load init file";
  -1"  -root <path>      Project root";
  exit 0}

/ Debug: run single file in-process with \e 1
debugSingle:{[file]
  debugMode::1b;
  system"e 1";
  / Override evalExpr: raw value for unexpected errors, trp for expected
  evalExpr::{[expr;pretty]
    fmt:$[pretty;s1Pretty;s1];
    dexp:debugExpected;
    if[(0<count dexp)&"'"~first dexp;
      :trp[{[f;e] r:value e; (f r;"";"")}[fmt];expr;{[err;bt] ("";"'",err;sbt bt)}]];
    r:value expr;
    (fmt r;"";"")};
  -2"[qdust debug] Errors break to q)). Expected errors are caught.";
  -2"[qdust debug] File: ",file;
  oneCmdTestFile file}

/ Debug: emit bash script for multiple files
/ Writes script and prints path — user runs it in their shell (terminal attached).
/ Generated dir: <qdust home>/generated/ by default, override with QDUST_DEBUG_DIR
/ NOTE: on Windows, change /tmp to an appropriate temp directory
debugMulti:{[files;flags]
  genDir:@[getenv;"QDUST_DEBUG_DIR";{""}];
  if[0=count genDir;
    genDir:(dirOf qdustPath),"/generated"];
  system"mkdir -p ",genDir;
  ts:string`long$.z.P;
  script:genDir,"/qdust-debug-",ts,".sh";
  / Build command prefix
  pfx:qEnvPrefix[],qExec[]," ",qFlags[],qdustPath," -debug ";
  flg:$[0<count flags;flags," ";""];
  lines:enlist"#!/bin/bash";
  lines:lines,enlist"# Generated by qdust -debug at ",string .z.P;
  lines:lines,enlist"# Files: ",string count files;
  lines:lines,enlist"";
  lines:lines,{[p;f;fl] p,fl,"test \"",f,"\""}'[pfx;files;count[files]#enlist flg];
  (hsym`$script)0:lines;
  system"chmod +x ",script;
  / Write pointer file so bash wrapper knows the exact script path
  / PID suffix from QDUST_DEBUG_PID makes this parallel-safe
  pid:@[getenv;"QDUST_DEBUG_PID";{"0"}];
  (hsym`$genDir,"/.debug-script-",pid)0:enlist script;
  -2"[qdust debug] ",string[count files]," files -> ",script;
  exit 0}

debugMain:{
  r:parseArgs[("-init";"-root";"-fn";"-filter");.z.x];
  d:r 0;pos:r 1;
  if[(`$"-init")in key d;initFile::d`$"-init"];
  if[(`$"-root")in key d;projectRoot::d`$"-root"];
  if[(`$"-fn")in key d;filterFn::`$d`$"-fn"];
  loadInit[];
  cmd:$[0<count pos;pos 0;""];
  target:$[1<count pos;pos 1;""];
  if[(not cmd~"test")|0=count target;debugHelp[]];
  / Build extra flags to pass through
  flags:"";
  if[(`$"-fn")in key d;flags:flags,"-fn ",d[`$"-fn"]," "];
  if[(`$"-init")in key d;flags:flags,"-init ",d[`$"-init"]," "];
  / Resolve target to file list
  files:resolveTarget target;
  filt:$[(`$"-filter")in key d;d`$"-filter";""];
  if[0<count filt;files:filterFiles[files;filt]];
  if[0=count files;-2"No test files found.";exit 1];
  / Single file: run in-process. Multiple: generate script.
  $[1=count files;
    debugSingle first files;
    debugMulti[files;flags]]}

/ ============================================================================
/ File Discovery (multi-file orchestrator)
/ ============================================================================

/ Check if string contains glob characters
isPattern:{[s] any s in"*?["}

/ Check if path is a directory (pure Q)
isDir:{[path] $[()~key hsym`$path;0b;11h=type key hsym`$path]}

/ Check if path is a file
isFile:{[path]
  @[{0<count system"test -f ",x," && echo 1"};path;{0b}]}

/ Check if path looks like a glob pattern
isGlob:{[path] 0<sum path in"*?[]"}

/ Expand glob pattern using bash (supports ** with globstar)
expandGlob:{[pattern]
  cmd:"bash -c 'shopt -s globstar nullglob 2>/dev/null; ls -d ",pattern," 2>/dev/null' | grep -E \"[.](q|t)$\"";
  @[system;cmd;{()}]}

/ Find test files in directory (recursive)
findTestFiles:{[path]
  p:$["/"=last path;-1_path;path];
  cmd:"find \"",p,"\" -type f \\( -name \"*.q\" -o -name \"*.t\" \\) ";
  cmd:cmd,"! -path \"*/.git/*\" ! -path \"*/node_modules/*\" ! -name \"*qdust*\" ! -name \"*DESIGN*\" 2>/dev/null | sort";
  files:@[system;cmd;{()}];
  files}

/ Find files matching pattern (recursive from current or specified dir)
findByPattern:{[pattern]
  slashPositions:where pattern="/";
  hasDir:0<count slashPositions;
  dir:$[hasDir;(last slashPositions)#pattern;"."];
  pat:$[hasDir;(1+last slashPositions)_pattern;pattern];
  cmd:"find ",dir," -type f -name \"",pat,"\" 2>/dev/null | grep -v qdust | grep -v DESIGN | sort";
  files:system cmd;
  files}

/ Filter file list by substring or glob pattern
/ Matches against paths relative to the search root
filterFiles:{[files;pattern]
  if[0=count pattern;:files];
  / If pattern has glob chars, use like; otherwise substring match
  isGlobPat:0<sum pattern in"*?[]";
  pat:$[isGlobPat;pattern;"*",pattern,"*"];
  files where files like\:pat}

/ Resolve target to list of files
resolveTarget:{[target]
  $[isPattern target;
    [files:findByPattern target;
     if[0=count files;
       -2"No files matching pattern: ",target;
       :()];
     files];
    isFile target;
    enlist target;
    isDir target;
    [files:findTestFiles target;
     if[0=count files;
       -2"No test files found in: ",target;
       :()];
     files];
    [files:findByPattern target;
     if[0=count files;
       -2"No files found: ",target;
       :()];
     files]]}

/ ============================================================================
/ Multi-File Runner
/ ============================================================================

/ Initialize settings from environment
initSettings:{
  ci:@[getenv;"CI";{""}];
  if[ci in("true";"1";"yes");
    diffMode::`console;
    launchDiffEnabled::0b;
    :()];
  qd:@[getenv;"QDUST_DIFF";{""}];
  if[qd~"none";diffMode::`none];
  if[qd~"ide";diffMode::`ide];
  ld:@[getenv;"QDUST_LAUNCH_DIFF";{""}];
  if[ld~"false";launchDiffEnabled::0b];
  if[ld~"true";launchDiffEnabled::1b];
  rd:@[getenv;"QDUST_RERUN_AFTER_DIFF";{""}];
  if[rd~"true";rerunAfterDiff::1b];
  if[rd~"false";rerunAfterDiff::0b];
  am:@[getenv;"QDUST_AUTO_MERGE_NEW";{""}];
  if[am~"true";autoMergeNew::1b];
  if[am~"false";autoMergeNew::0b]}

/ Run single file as subprocess, capture results
/ batchMode: if true, use -batchdiffs (minimal output, no IDE)
runSingleFile:{[file;batchMode]
  flags:$[junit;"-junit ";json;"-json ";""];
  flags:flags,$[batchMode;"-batchdiffs ";""];
  flags:flags,$[errorsOnly;"-errors-only ";""];
  flags:flags,$[listci;"-listci ";""];
  flags:flags,$[autoMergeNew;"-auto-merge-new ";""];
  / Use temp file and bash wrapper to capture output
  tmpf:"/tmp/qdust_",string[`int$.z.t],".txt";
  shf:"/tmp/qdust_cmd.sh";
  (hsym`$shf)0:enlist qEnvPrefix[],qExec[]," ",qFlags[],qdustPath," -one ",flags,"test \"",file,"\" > ",tmpf," 2>&1";
  @[system;"bash ",shf;{}];
  output:@[read0;hsym`$tmpf;enlist""];
  @[system;"rm -f ",tmpf," ",shf;{}];
  / Ensure output is always a list of strings
  if[10h=type output;output:enlist output];
  / Parse from batch output format: "PASS/FAIL file: N passed, M failed [Nms hash:XXXX]"
  failCount:0;
  passCount:0;
  corrFile:"";
  fileDurMs:0;
  fhash:0;
  errors:();
  foundResult:0b;
  i:0;
  while[i<count output;
    line:output i;
    n:count line;
    if[(n>5)&"PASS "~5#line;
      parts:" "vs line;
      passCount:"J"$parts 2;
      failCount:0;
      foundResult:1b];
    if[(n>5)&"FAIL "~5#line;
      parts:" "vs line;
      passCount:"J"$parts 2;
      failCount:"J"$parts 4;
      foundResult:1b];
    if[(n>10)&"  Passed:"~9#line;
      passCount:"J"$last" "vs line;
      foundResult:1b];
    if[(n>10)&"  Failed:"~9#line;
      failCount:"J"$last" "vs line;
      foundResult:1b];
    if[(n>6)&"File \""~6#line;
      errors:errors,enlist line];
    / Parse timing/hash: [Nms hash:XXXX]
    if[n>0;
      bi:line ss"[";
      if[0<count bi;
        bracket:((last bi)+1)_line;
        bracket:bracket except"]";
        if[bracket like"*ms hash:*";
          bp:" "vs bracket;
          fileDurMs:"J"$(-2)_first bp;
          fhash:"J"$last":"vs last bp]]];
    i:i+1];
  / If no PASS/FAIL line found but output exists, treat as failure
  if[(not foundResult)&0<count output;
    failCount:1;
    errors:output where (output like\:"Error*")|(output like\:"*error*")|(output like\:"*'*")];
  `file`output`passed`failed`success`corrected`errors`duration_ms`hash!(file;output;passCount;failCount;0=failCount;corrFile;errors;fileDurMs;fhash)}

/ Run single file via IPC worker — native Q data, no stdout parsing
/ Returns same dict shape as runSingleFile for seamless switching
runSingleFileIpc:{[file;batchMode]
  fileStart:.z.P;
  / 1. Start worker
  port:@[ipcRandomPort;`;{'"IPC port: ",x}];
  pid:@[ipcStartWorker;port;{0Ni}];
  if[null pid;
    -2"IPC: Failed to start worker for ",file;
    :`file`output`passed`failed`success`corrected`errors`duration_ms`hash!(file;();0;1;0b;"";enlist"IPC: worker start failed";0;0)];
  h:@[ipcConnect;port;{0Ni}];
  if[null h;
    @[system;"kill ",string[pid]," 2>/dev/null";{}];
    -2"IPC: Failed to connect to worker for ",file;
    :`file`output`passed`failed`success`corrected`errors`duration_ms`hash!(file;();0;1;0b;"";enlist"IPC: connect failed";0;0)];
  / 2. Load and parse on worker
  lp:@[h;(`.qd.w.loadAndParse;file);{(();();"";"IPC error: ",x)}];
  tests:lp 0;lines:lp 1;fhash:"J"$lp 2;loadErr:lp 3;
  if[0<count loadErr;
    @[hclose;h;{}];
    @[system;"kill ",string[pid]," 2>/dev/null";{}];
    -2"Error: ",loadErr;
    :`file`output`passed`failed`success`corrected`errors`duration_ms`hash!(file;();0;1;0b;"";enlist loadErr;0;fhash)];
  / 3. Filter by function if -fn specified
  if[not filterFn~`;
    tests:tests where tests[`fn]=filterFn;
    if[0=count tests;
      @[hclose;h;{}];
      @[system;"kill ",string[pid]," 2>/dev/null";{}];
      fileDurMs:(`long$.z.P-fileStart)div 1000000;
      :`file`output`passed`failed`success`corrected`errors`duration_ms`hash!(file;();0;0;1b;"";();fileDurMs;fhash)]];
  if[0=count tests;
    @[hclose;h;{}];
    @[system;"kill ",string[pid]," 2>/dev/null";{}];
    fileDurMs:(`long$.z.P-fileStart)div 1000000;
    :`file`output`passed`failed`success`corrected`errors`duration_ms`hash!(file;();0;0;1b;"";();fileDurMs;fhash)];
  / 4. Override evalExpr to route through IPC worker, then run tests
  savedEval:evalExpr;
  evalExpr::{[hh;expr;pretty]
    r:@[hh;(`.qd.w.runExpr;expr;pretty);{("";x;"")}];
    3#r}[h];
  results:@[runTests[file;tests];0b;{[se;e] evalExpr::se;(::)}[savedEval]];
  evalExpr::savedEval;
  / 5. Kill worker
  @[hclose;h;{}];
  @[system;"kill ",string[pid]," 2>/dev/null";{}];
  / 6. Build output
  if[(::)~results;
    :`file`output`passed`failed`success`corrected`errors`duration_ms`hash!(file;();0;1;0b;"";enlist"IPC: runTests failed";0;fhash)];
  if[isSilentErr results;
    printSilentErr[file;results];
    errMsg:"Setup error (line ",string[results`line],"): ",results`error;
    :`file`output`passed`failed`success`corrected`errors`duration_ms`hash!(file;();0;1;0b;"";enlist errMsg;0;fhash)];
  pr:processResults[file;lines;results];
  testSums:pr 0;cf:pr 1;autoMerged:pr 2;
  failed:results where results[`changeType]in`modified`error;
  tp:sum testSums[`passed];tf:sum testSums[`failed];tnew:sum testSums[`new];
  fileDurMs:(`long$.z.P-fileStart)div 1000000;
  / Batch output line (matches subprocess format)
  if[batchMode;
    status:$[0=tf;"PASS";"FAIL"];
    suffix:$[autoMerged;" (auto-merged)";0<tnew;", ",string[tnew]," new";""];
    -1 status," ",file,": ",string[tp]," passed, ",string[tf]," failed",suffix," [",string[fileDurMs],"ms hash:",string[fhash],"]";
    if[0<count cf;-1"  .corrected: ",cf]];
  errors:$[0<count failed;{[f;r] formatErrorLine[f;r]}[file]each failed;()];
  `file`output`passed`failed`success`corrected`errors`duration_ms`hash!(file;();tp;tf;0=tf;cf;errors;fileDurMs;fhash)}

runAllFiles:{[files;batchMode]
  results:();
  totalPassed:0;
  totalFailed:0;
  totalFiles:0;
  failedFiles:();
  filesWithDiffs:();

  i:0;
  while[i<count files;
    file:files i;
    r:$[ipcMode;runSingleFileIpc[file;batchMode];runSingleFile[file;batchMode]];
    r[`category]:detectCategory file;

    totalPassed:totalPassed+r`passed;
    totalFailed:totalFailed+r`failed;
    totalFiles:totalFiles+1;

    if[not r`success;
      failedFiles:failedFiles,enlist file];

    if[0<count r`corrected;
      filesWithDiffs:filesWithDiffs,enlist file];

    results:results,enlist r;
    i:i+1];

  allErrors:raze results`errors;
  `results`totalPassed`totalFailed`totalFiles`failedFiles`filesWithDiffs`allErrors!(results;totalPassed;totalFailed;totalFiles;failedFiles;filesWithDiffs;allErrors)}

/ ============================================================================
/ IDE Diff Processing
/ ============================================================================

getDiffCmd:{
  dt:@[getenv;"QDUST_DIFF_TOOL";{""}];
  if[0<count dt;:dt];
  os:first system"uname";
  $[os~"Darwin";"open -W -a FileMerge";
    os~"Linux";"meld";
    "diff"]}

launchIdeDiff:{[file]
  corrFile:file,".corrected";
  if[()~key hsym`$corrFile;
    -1"No .corrected file for ",file;
    :0b];
  diffCmd:getDiffCmd[];
  cmd:diffCmd," ",file," ",corrFile," 2>/dev/null";
  -1"Opening diff: ",file," vs ",corrFile;
  system cmd;
  not()~key hsym`$corrFile}

processDiffs:{[filesWithDiffs]
  if[0=count filesWithDiffs;:()];
  -1"\n========================================";
  -1"Processing ",string[count filesWithDiffs]," file(s) with diffs";
  -1"========================================\n";

  i:0;
  while[i<count filesWithDiffs;
    file:filesWithDiffs i;
    -1"\n[",string[i+1],"/",string[count filesWithDiffs],"] ",file;

    stillHasDiff:launchIdeDiff file;

    if[stillHasDiff & rerunAfterDiff;
      -1"Rerunning tests for ",file,"...";
      r:runSingleFile[file;0b];
      $[r`success;-1"PASS - All tests pass, .corrected removed";-1"FAIL - Still has failures, .corrected kept"]];

    i:i+1];

  -1"\nDiff processing complete."}

/ ============================================================================
/ Multi-File Output
/ ============================================================================

pad:{[s;w] s,(w-count s)#" "}

basename:{[p] s:last"/"vs p; $[0<count s;s;p]}

printCiLinks:{[summary]
  if[0=count summary`allErrors;:()];
  -1"\nCI Error Links:";
  i:0;
  while[i<count summary`allErrors;
    -1 summary[`allErrors]i;
    i:i+1]}

rpad:{[s;w] s,(w-count s)#" "}
lpad:{[s;w] ((w-count s)#" "),s}

printSummary:{[summary]
  fnames:basename each summary[`results][`file];
  fw:2+max count each fnames;
  / Header
  -1"";
  -1 rpad["File";fw],"  Pass  Fail  Total";
  -1(fw+22)#"-------------------------------------------------------------";
  / Rows
  i:0;
  while[i<count summary`results;
    r:summary[`results]i;
    fn:basename r`file;
    tp:string r`passed;tf:string r`failed;
    tt:string r[`passed]+r[`failed];
    mark:$[r`success;" ";"*"];
    -1 mark,rpad[fn;fw-1],lpad[tp;4],"  ",lpad[tf;4],"  ",lpad[tt;5];
    i:i+1];
  -1(fw+22)#"-------------------------------------------------------------";
  tp:string summary`totalPassed;tf:string summary`totalFailed;
  tt:string summary[`totalPassed]+summary[`totalFailed];
  -1 rpad["Total";fw],lpad[tp;4],"  ",lpad[tf;4],"  ",lpad[tt;5];
  -1"";
  $[0=summary`totalFailed;-1"ALL TESTS PASSED";-1"SOME TESTS FAILED"]}

printJsonSummary:{[summary]
  -1"{";
  -1"  \"files_tested\": ",string[summary`totalFiles],",";
  -1"  \"total_passed\": ",string[summary`totalPassed],",";
  -1"  \"total_failed\": ",string[summary`totalFailed],",";
  -1"  \"failed_files\": [";
  nf:count summary`failedFiles;
  i:0;
  while[i<nf;
    cm:$[i<nf-1;",";""];
    -1"    \"",summary[`failedFiles][i],"\"",cm;
    i:i+1];
  -1"  ],";
  -1"  \"file_results\": [";
  nr:count summary`results;
  i:0;
  while[i<nr;
    r:summary[`results][i];
    cm:$[i<nr-1;",";""];
    -1"    {\"file\": \"",r[`file],"\", \"passed\": ",string[r`passed],", \"failed\": ",string[r`failed],"}",cm;
    i:i+1];
  -1"  ]";
  -1"}"}

/ ============================================================================
/ Test Report System
/ ============================================================================

/ Resolve report file path
resolveReportPath:{
  if[0<count reportFile;:reportFile];
  root:$[0<count projectRoot;projectRoot;first system"pwd"];
  root:$["/"=last root;root;root,"/"];
  root,".qdust-report.json"}

/ Extract integer value from JSON lines for a given field name
jsonExI:{[lines;field]
  pat:"\"",field,"\":";
  m:lines where lines like\:("*",pat,"*");
  if[0=count m;:0N];
  line:first m;
  idx:(first line ss pat)+count pat;
  "J"$trim(idx _line)except","}

/ Extract string value from JSON lines for a given field name
jsonExS:{[lines;field]
  pat:"\"",field,"\":";
  m:lines where lines like\:("*",pat,"*");
  if[0=count m;:""];
  line:first m;
  idx:(first line ss pat)+count pat;
  rest:trim(idx _line)except",";
  1_(-1_rest)}

/ Read previous report from JSON file
/ Returns dict with key fields or () if not found
readPrevReport:{[path]
  if[noReport;:()];
  if[()~key hsym`$path;:()];
  lines:@[read0;hsym`$path;{()}];
  if[0=count lines;:()];
  `version`timestamp`duration_ms`files_tested`total_tests`total_passed`total_failed`total_new!(
    jsonExI[lines;"version"];
    jsonExS[lines;"timestamp"];
    jsonExI[lines;"duration_ms"];
    jsonExI[lines;"files_tested"];
    jsonExI[lines;"total_tests"];
    jsonExI[lines;"total_passed"];
    jsonExI[lines;"total_failed"];
    jsonExI[lines;"total_new"])}

/ Format a single file result as JSON
reportFileJson:{[r;isLast]
  dur:$[`duration_ms in key r;r`duration_ms;0];
  h:$[`hash in key r;r`hash;0];
  cat:$[`category in key r;string r`category;"preflight"];
  cm:$[isLast;"";"," ];
  "    {\"file\": \"",jsonEscape[r`file],"\", \"category\": \"",cat,"\", \"tests\": ",string[r[`passed]+r[`failed]],", \"passed\": ",string[r`passed],", \"failed\": ",string[r`failed],", \"duration_ms\": ",string[dur],", \"hash\": ",string[h],"}",cm}

/ Write report JSON to file
/ Build report JSON lines
reportLines:{[summary;runDurMs]
  tp:summary`totalPassed;tf:summary`totalFailed;
  tt:tp+tf;nf:summary`totalFiles;
  L:(enlist"{";
    "  \"version\": 1,";
    "  \"timestamp\": \"",string[.z.P],"\",";
    "  \"duration_ms\": ",string[runDurMs],",";
    "  \"q_version\": \"",string[.z.K]," ",string[.z.k],"\",";
    "  \"files_tested\": ",string[nf],",";
    "  \"total_tests\": ",string[tt],",";
    "  \"total_passed\": ",string[tp],",";
    "  \"total_failed\": ",string[tf],",";
    "  \"total_new\": 0,";
    "  \"gates\": {";
    "    \"min_tests\": ",$[null minTests;"null";string minTests],",";
    "    \"min_pass\": ",$[null minPass;"null";$[minPassPct;"\"",string[minPass],"%\"";string minPass]];
    "  },";
    "  \"files\": [");
  nr:count summary`results;
  i:0;
  while[i<nr;L:L,enlist reportFileJson[summary[`results]i;i=nr-1];i:i+1];
  L,("  ]";enlist"}")}

writeReport:{[path;summary;runDurMs]
  if[noReport;:()];
  L:reportLines[summary;runDurMs];
  @[(hsym`$path)0:;L;{-2"Warning: Failed to write report: ",x}]}

/ Check gates (explicit thresholds). Returns 1b if any gate fails.
checkGates:{[summary]
  tp:summary`totalPassed;tt:tp+summary`totalFailed;
  fail:0b;
  if[tt=0;-2"GATE FAIL: No tests executed";fail:1b];
  if[(not null minTests)&tt<minTests;
    -2"GATE FAIL: Total tests ",string[tt]," below minimum ",string[minTests];fail:1b];
  if[not null minPass;
    threshold:$[minPassPct;ceiling(minPass%100)*tt;minPass];
    label:$[minPassPct;string[minPass],"%";string minPass];
    if[tp<threshold;
      -2"GATE FAIL: Passed ",string[tp]," below minimum ",label,$[minPassPct;" (",string[threshold]," of ",string[tt],")";""]; fail:1b]];
  fail}

/ Compare current run against previous report. Returns (hardFail;warnings).
compareReport:{[prv;summary]
  if[()~prv;:(0b;())];
  tp:summary`totalPassed;tt:tp+summary`totalFailed;
  nf:summary`totalFiles;w:();fail:0b;
  / Gate: catastrophic drop (>50%)
  if[(prv[`total_tests]>0)&tt<prv[`total_tests]div 2;
    -2"GATE FAIL: Test count dropped >50% (",string[prv`total_tests]," -> ",string[tt],")";
    fail:1b];
  if[tt<prv`total_tests;
    w,:enlist"Test count decreased: ",string[prv`total_tests]," -> ",string tt];
  if[tp<prv`total_passed;
    w,:enlist"Pass count decreased: ",string[prv`total_passed]," -> ",string tp];
  if[nf<prv`files_tested;
    w,:enlist"Files tested decreased: ",string[prv`files_tested]," -> ",string nf];
  if[(0<count prv`timestamp)&prv[`timestamp]~string .z.P;
    w,:enlist"Timestamp identical to previous run -- results may be stale"];
  if[0<count w;
    -2"";-2"--- Verification Warnings ---";{-2"  WARNING: ",x}each w];
  (fail;w)}

/ Apply gates and compare against previous report
/ Returns (hardFail;warnings)
applyGates:{[prv;summary;durMs]
  gf:checkGates summary;
  cr:compareReport[prv;summary];
  (gf|cr 0;cr 1)}

/ Print verification section after summary
printVerification:{[prv;summary;durMs]
  tp:summary`totalPassed;tf:summary`totalFailed;
  tt:tp+tf;nf:summary`totalFiles;
  -1"\n--- Verification ---";
  -1"  Timestamp:  ",string .z.P;
  -1"  Duration:   ",string[durMs],"ms";
  if[not()~prv;
    delta:{[p;c] d:c-p; s:$[d>0;"+",string d;d<0;string d;"unchanged"]; string[c]," (was ",string[p],", ",s,")"};
    -1"  Tests:      ",delta[prv`total_tests;tt];
    -1"  Passed:     ",delta[prv`total_passed;tp];
    -1"  Files:      ",delta[prv`files_tested;nf]];
  -1"  Report:     ",resolveReportPath[]}

/ ============================================================================
/ Orchestrator Commands
/ ============================================================================

promoteAll:{[dir]
  cmd:"find ",dir," -name \"*.corrected\" 2>/dev/null";
  files:system cmd;
  if[0=count files;
    -1"No .corrected files found in ",dir;
    :0];

  promoted:0;
  i:0;
  while[i<count files;
    corrFile:files i;
    origFile:(count[corrFile]-10)#corrFile;
    content:read0 hsym`$corrFile;
    (hsym`$origFile)0:content;
    hdel hsym`$corrFile;
    -1"Promoted: ",origFile;
    promoted:promoted+1;
    i:i+1];

  -1"\nPromoted ",string[promoted]," file(s)";
  promoted}

promoteByPattern:{[pattern]
  slashPositions:where pattern="/";
  hasDir:0<count slashPositions;
  dir:$[hasDir;(last slashPositions)#pattern;"."];
  pat:$[hasDir;(1+last slashPositions)_pattern;pattern];
  cmd:"find ",dir," -type f -name \"",pat,"\" 2>/dev/null";
  files:system cmd;
  if[0=count files;
    -1"No .corrected files matching: ",pattern;
    :0];

  promoted:0;
  i:0;
  while[i<count files;
    corrFile:files i;
    origFile:(count[corrFile]-10)#corrFile;
    content:read0 hsym`$corrFile;
    (hsym`$origFile)0:content;
    hdel hsym`$corrFile;
    -1"Promoted: ",origFile;
    promoted:promoted+1;
    i:i+1];

  -1"\nPromoted ",string[promoted]," file(s)";
  promoted}

/ Run report system and return exit code
testExit:{[summary;durMs]
  rp:resolveReportPath[];
  pr:readPrevReport rp;
  gr:applyGates[pr;summary;durMs];
  printVerification[pr;summary;durMs];
  writeReport[rp;summary;durMs];
  $[gr 0;1;0=summary`totalFailed;0;1]}

cmdTest:{[target;filt]
  files:resolveTarget target;
  if[0=count files;exit 1];
  if[0<count filt;
    files:filterFiles[files;filt];
    if[0=count files;
      -2"No files matching filter: ",filt;
      exit 1]];
  / Filter by category (preflight/integration)
  if[not testCategory~`all;
    cats:detectCategory each files;
    kept:files where cats=testCategory;
    skipped:(count files)-count kept;
    if[skipped>0;
      other:$[testCategory~`preflight;"integration";"preflight"];
      -2 other," tests skipped, use -",other," or -all to run them"];
    files:kept;
    if[0=count files;
      -2"No ",string[testCategory]," test files found";
      exit 1]];

  / Single file - run via -one and capture output via temp file
  if[1=count files;
    file:first files;
    flags:$[junit;"-junit ";json;"-json ";""];
    flags:flags,$[errorsOnly;"-errors-only ";""];
    flags:flags,$[listci;"-listci ";""];
    flags:flags,$[autoMergeNew;"-auto-merge-new ";""];
    tmpf:"/tmp/qdust_single_",string[`int$.z.t],".txt";
    shf:"/tmp/qdust_single_cmd.sh";
    (hsym`$shf)0:enlist qEnvPrefix[],qExec[]," ",qFlags[],qdustPath," -one ",flags,"test \"",file,"\" > ",tmpf," 2>&1";
    @[system;"bash ",shf;{}];
    output:@[read0;hsym`$tmpf;enlist""];
    @[system;"rm -f ",tmpf," ",shf;{}];
    {-1 x}each output;
    corrFile:file,".corrected";
    exit $[()~key hsym`$corrFile;0;1]];

  / Multiple files - use batch mode unless listci needs full output
  -1"Found ",string[count files]," test file(s)\n";
  runStart:.z.P;
  summary:runAllFiles[files;not listci];
  runDurMs:(`long$.z.P-runStart)div 1000000;
  $[json;printJsonSummary summary;printSummary summary];

  / Print error details below summary
  if[(not json)&0<count summary`allErrors;
    -1"\n--- Errors ---";
    i:0;
    while[i<count summary`allErrors;
      -1"  ",summary[`allErrors]i;
      i:i+1]];

  if[listci;printCiLinks summary];

  if[(diffMode~`ide)&launchDiffEnabled&(0<count summary`filesWithDiffs);
    processDiffs summary`filesWithDiffs];

  / Report system: read previous, compare, write new
  exit testExit[summary;runDurMs]}

cmdPromote:{[target]
  $[isPattern target;
    [pat:$[target like"*.q";(-2_target),".q.corrected";
           target like"*.t";(-2_target),".t.corrected";
           target,".corrected"];
     n:promoteByPattern pat;
     exit $[0<n;0;1]];
    isDir target;
    [n:promoteAll target;exit $[0<n;0;1]];
    [cmd:qEnvPrefix[],qExec[]," ",qdustPath," -one promote ",target;
     @[system;cmd;{}];
     exit 0]]}

cmdGitignore:{
  giPath:".gitignore";
  patterns:enlist"*.corrected";
  existing:$[()~key hsym`$giPath;();read0 hsym`$giPath];
  toAdd:patterns where not patterns in existing;

  if[0=count toAdd;
    -1".gitignore already contains qdust patterns";
    exit 0];

  newContent:existing,toAdd;
  (hsym`$giPath)0:newContent;

  -1"Added to .gitignore:";
  {-1"  ",x} each toAdd;
  exit 0}

/ Check for stale .corrected files (CI pre-check)
cmdCheck:{[dir]
  corrCmd:"find ",dir," -name \"*.corrected\" 2>/dev/null";
  corrFiles:system corrCmd;
  corrFiles:corrFiles where 0<count each corrFiles;

  if[0=count corrFiles;
    -1"OK: No .corrected files found";
    exit 0];

  -1"ERROR: Found ",string[count corrFiles]," stale .corrected file(s)";
  -1"";
  -1"Run 'qdust promote' or fix tests:";
  {-1"  ",x} each corrFiles;
  -1"";
  -1"These indicate uncommitted test changes.";
  exit 1}

help:{
  -1"qdust - Q/K Expect Test Runner";
  -1"";
  -1"Usage:";
  -1"  q qdust.q test                   Test all files in project (.qd/.git root)";
  -1"  q qdust.q test -filter <pat>      Filter project files by name/glob";
  -1"  q qdust.q test <dir>             Test all files in directory (CWD-relative)";
  -1"  q qdust.q test <file.q>          Test single file (CWD-relative)";
  -1"  q qdust.q test <pattern>         Test files matching glob (CWD-relative)";
  -1"  q qdust.q promote <dir>          Promote all .corrected files in directory";
  -1"  q qdust.q promote <file.q>       Promote single file";
  -1"  q qdust.q promote <pattern>      Promote matching .corrected files";
  -1"  q qdust.q check [dir]            Fail if .corrected files exist (CI)";
  -1"  q qdust.q gitignore              Add *.corrected to .gitignore";
  -1"";
  -1"Options:";
  -1"  -json                           Output in JSON format";
  -1"  -junit                          Output in JUnit XML format (for CI)";
  -1"  -errors-only                    Show only errors, not full output";
  -1"  -listci                         CI-clickable error format";
  -1"  -nodiff                         Summary only, no diff output";
  -1"  -condiff                        Console diff (default)";
  -1"  -idediff                        Open IDE diff tool";
  -1"  -launch-diff                    Launch IDE diff for each file with diffs";
  -1"  -no-launch-diff                 Don't launch IDE diff";
  -1"  -rerun-after-diff               Rerun tests after diff tool closes";
  -1"  -no-rerun-after-diff            Don't rerun after diff";
  -1"  -auto-merge-new                 Auto-promote if only new tests (no changes)";
  -1"  -no-auto-merge-new              Require manual review for all (default)";
  -1"  -debug                          Debug mode (single file, errors break to q))";
  -1"  -noipc                          Disable IPC worker mode (use subprocess instead)";
  -1"  -timeout <N>                    Per-expression timeout in seconds (default 5, IPC mode)";
  -1"  -integration                    Run only @integration tests";
  -1"  -all                            Run all tests (preflight + integration)";
  -1"";
  -1"Environment:";
  -1"  QDUST_DIFF                       Diff tool command (e.g. \"code --diff\", \"idea diff\")";
  -1"  QDUST_TIMEOUT                    Per-expression timeout in seconds (IPC mode)";
  -1"  QDUST_PORTS                      IPC port range (e.g. \"10000..65535\")";
  -1"";
  -1"Patterns:";
  -1"  Patterns containing *, ?, or [ are treated as globs";
  -1"  Patterns are searched recursively by default";
  -1"";
  -1"Examples:";
  -1"  q qdust.q test                   Run all tests in current directory";
  -1"  q qdust.q test tests/            Run all tests in tests/ directory";
  -1"  q qdust.q test myfile.q          Run tests in single file";
  -1"  q qdust.q test \"test_*.q\"        Run tests matching pattern";
  -1"  q qdust.q test \"src/**/test*.q\"  Run tests in src/ tree";
  -1"  q qdust.q promote tests/         Accept all .corrected files";
  -1"";
  -1"IDE Diff Workflow:";
  -1"  q qdust.q -idediff -rerun-after-diff test tests/";
  -1"  # Runs all tests, then opens diff tool for each failure.";
  -1"  # After closing diff tool, reruns that file's tests.";
  -1"  # If pass, continues to next file. If fail, shows result.";
  exit 0}

/ ============================================================================
/ Main (orchestrator)
/ ============================================================================

main:{
  initSettings[];
  r:parseArgs[("-filter";"-min-tests";"-min-pass";"-report-file";"-timeout");.z.x];
  d:r 0;pos:r 1;
  if[(`$"-json")in key d;json::1b];
  if[(`$"-junit")in key d;junit::1b];
  if[(`$"-errors-only")in key d;errorsOnly::1b];
  if[(`$"-listci")in key d;listci::1b];
  if[any(`$"-v";`$"-verbose")in key d;verbose::1b];
  if[(`$"-nodiff")in key d;diffMode::`none];
  if[(`$"-condiff")in key d;diffMode::`console];
  if[(`$"-idediff")in key d;diffMode::`ide];
  if[(`$"-launch-diff")in key d;launchDiffEnabled::1b];
  if[(`$"-no-launch-diff")in key d;launchDiffEnabled::0b];
  if[(`$"-rerun-after-diff")in key d;rerunAfterDiff::1b];
  if[(`$"-no-rerun-after-diff")in key d;rerunAfterDiff::0b];
  if[(`$"-auto-merge-new")in key d;autoMergeNew::1b];
  if[(`$"-no-auto-merge-new")in key d;autoMergeNew::0b];
  if[(`$"-no-report")in key d;noReport::1b];
  if[(`$"-min-tests")in key d;minTests::"J"$d`$"-min-tests"];
  if[(`$"-min-pass")in key d;
    mpv:d`$"-min-pass";
    $["%"=last mpv;
      [minPassPct::1b;minPass::"J"$(-1)_mpv];
      minPass::"J"$mpv]];
  if[(`$"-report-file")in key d;reportFile::d`$"-report-file"];
  if[(`$"-integration")in key d;testCategory::`integration];
  if[(`$"-all")in key d;testCategory::`all];
  if[(`$"-noipc")in key d;ipcMode::0b];
  if[(`$"-timeout")in key d;ipcTimeout::"J"$d`$"-timeout"];
  / Read QDUST_TIMEOUT env var if -timeout not given
  if[not(`$"-timeout")in key d;
    tv:@[getenv;"QDUST_TIMEOUT";{""}];
    if[0<count tv;ipcTimeout::"J"$tv]];
  filt:$[(`$"-filter")in key d;d`$"-filter";""];
  cmd:$[0<count pos;pos 0;""];
  / No target (or -f without target): find project root from CWD
  target:$[1<count pos;pos 1;
    [cwd:first system"pwd";
     root:findRoot cwd;
     $[0<count root;-1_root;cwd]]];  / strip trailing / from root
  $[cmd~"test";cmdTest[target;filt];
    cmd~"promote";cmdPromote target;
    cmd~"check";cmdCheck target;
    cmd~"gitignore";cmdGitignore[];
    help[]]}

/ ============================================================================
/ Worker Mode (-worker, used by IPC orchestrator)
/ ============================================================================

/ Worker: load file, parse tests, load deps, return native Q data
/ Returns (tests;lines;fhash_string;error) — fhash as string for IPC
.qd.w.loadAndParse:{[file]
  r:prepareFile file;
  (r 0;r 1;string r 2;r 3)}

/ Worker: evaluate a single expression with timing
/ Returns (formatted_result;error_string;backtrace_string;duration_ms)
.qd.w.runExpr:{[expr;pretty]
  t0:.z.P;
  r:evalExpr[expr;pretty];
  durMs:(`long$.z.P-t0)div 1000000;
  (r 0;r 1;r 2;durMs)}

/ Worker main: parse -timeout, set \T, then wait for IPC commands
workerMain:{
  r:parseArgs[("-timeout");.z.x];
  d:r 0;
  if[(`$"-timeout")in key d;ipcTimeout::"J"$d`$"-timeout"];
  if[ipcTimeout>0;system"T ",string ipcTimeout];
  / Worker is ready — orchestrator connects via IPC
  / .qd.w.loadAndParse and .qd.w.runExpr are callable over IPC
  }

\d .

/ ============================================================================
/ Entry Point Dispatch
/ ============================================================================

if[0<count .z.x;
  $["-worker"in .z.x;
    [.z.x:.z.x where not .z.x~\:"-worker";.qd.workerMain[]];
    "-debug"in .z.x;
    [.z.x:.z.x where not .z.x~\:"-debug";.qd.debugMain[]];
    "-one"in .z.x;
    [.z.x:.z.x where not .z.x~\:"-one";.qd.oneMain[]];
    .qd.main[]]]
