/ qdust.q - Multi-file Q/K Expect Test Runner
/ Finds and runs tests across multiple files using qdust1.q

/ Usage:
/   q qdust.q test                     Test all .q/.t files in current dir
/   q qdust.q test <dir>               Test all .q/.t files in directory
/   q qdust.q test <file.q>            Test single file
/   q qdust.q test <pattern>           Test files matching pattern (recursive)
/   q qdust.q promote <dir|pattern>    Promote .corrected files
/   q qdust.q --json test <target>     Output in JSON format

\d .qd

/ ============================================================================
/ Configuration
/ ============================================================================

json:0b
junit:0b
verbose:0b
listci:0b               / CI link format: clickable error locations
errorsOnly:0b           / Only show errors, not full output
diffMode:`console       / `none`console`ide
launchDiff:1b           / Launch IDE diff tool for each file with diffs
rerunAfterDiff:0b       / Rerun tests after diff tool closes
autoMergeNew:0b         / Auto-promote if only new tests (no modified/errors)

/ Get directory containing this script
scriptDir:{
  s:string .z.f;
  i:last where s="/";
  d:$[null i;".";i#s];
  $[()~key hsym`$(d,"/qdust1.q");".";d]}

/ Initialize settings from environment
initSettings:{
  / CI environment always defaults to console, no IDE
  ci:@[getenv;"CI";{""}];
  if[ci in("true";"1";"yes");
    diffMode::`console;
    launchDiff::0b;
    :()];
  / Check QDUST_DIFF env var
  qd:@[getenv;"QDUST_DIFF";{""}];
  if[qd~"none";diffMode::`none];
  if[qd~"ide";diffMode::`ide];
  / Check QDUST_LAUNCH_DIFF
  ld:@[getenv;"QDUST_LAUNCH_DIFF";{""}];
  if[ld~"false";launchDiff::0b];
  if[ld~"true";launchDiff::1b];
  / Check QDUST_RERUN_AFTER_DIFF
  rd:@[getenv;"QDUST_RERUN_AFTER_DIFF";{""}];
  if[rd~"true";rerunAfterDiff::1b];
  if[rd~"false";rerunAfterDiff::0b];
  / Check QDUST_AUTO_MERGE_NEW
  am:@[getenv;"QDUST_AUTO_MERGE_NEW";{""}];
  if[am~"true";autoMergeNew::1b];
  if[am~"false";autoMergeNew::0b]}

/ ============================================================================
/ File Discovery
/ ============================================================================

/ Check if string contains glob characters
isPattern:{[s] any s in"*?["}

/ Check if path is a directory
isDir:{[path]
  @[{0<count system"test -d ",x," && echo 1"};path;{0b}]}

/ Check if path is a file
isFile:{[path]
  @[{0<count system"test -f ",x," && echo 1"};path;{0b}]}

/ Find test files in directory (recursive)
findTestFiles:{[dir]
  cmd:"find ",dir," -type f \\( -name \"*.q\" -o -name \"*.t\" \\) 2>/dev/null | grep -v qdust | grep -v DESIGN | sort";
  files:system cmd;
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
/ Single File Testing (via qdust1.q)
/ ============================================================================

/ Run qdust1 on a single file, capture results
/ batchMode: if true, use --batchdiffs (minimal output, no IDE)
runSingleFile:{[file;batchMode]
  qPath:scriptDir[],"/qdust1.q";
  flags:$[junit;"--junit ";json;"--json ";""];
  flags:flags,$[batchMode;"--batchdiffs ";""];
  flags:flags,$[errorsOnly;"--errors-only ";""];
  flags:flags,$[listci;"--listci ";""];
  flags:flags,$[autoMergeNew;"--auto-merge-new ";""];
  / Use temp file and bash wrapper to capture output
  tmpf:"/tmp/qdust_",string[`int$.z.t],".txt";
  shf:"/tmp/qdust_cmd.sh";
  (hsym`$shf)0:enlist"q ",qPath," ",flags,"test \"",file,"\" > ",tmpf," 2>&1";
  @[system;"bash ",shf;{}];
  output:@[read0;hsym`$tmpf;enlist""];
  @[system;"rm -f ",tmpf," ",shf;{}];
  / Ensure output is always a list of strings
  if[10h=type output;output:enlist output];
  / Parse from batch output format: "PASS/FAIL file: N passed, M failed"
  failCount:0;
  passCount:0;
  corrFile:"";
  errors:();
  i:0;
  while[i<count output;
    line:output i;
    n:count line;
    / Batch format: "PASS file.q: 5 passed, 0 failed" or "FAIL file.q: 3 passed, 2 failed"
    if[(n>5)&"PASS "~5#line;
      parts:" "vs line;
      passCount:"J"$parts 2;
      failCount:0];
    if[(n>5)&"FAIL "~5#line;
      parts:" "vs line;
      passCount:"J"$parts 2;
      failCount:"J"$parts 4];
    / Non-batch format: "  Passed: N" and "  Failed: M"
    if[(n>10)&"  Passed:"~9#line;
      passCount:"J"$last" "vs line];
    if[(n>10)&"  Failed:"~9#line;
      failCount:"J"$last" "vs line];
    / Capture CI-format error lines: File "...", line N
    if[(n>6)&"File \""~6#line;
      errors:errors,enlist line];
    i:i+1];
  `file`output`passed`failed`success`corrected`errors!(file;output;passCount;failCount;0=failCount;corrFile;errors)}

/ ============================================================================
/ Multi-File Runner
/ ============================================================================

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
    r:runSingleFile[file;batchMode];

    totalPassed:totalPassed+r`passed;
    totalFailed:totalFailed+r`failed;
    totalFiles:totalFiles+1;

    if[not r`success;
      failedFiles:failedFiles,enlist file];

    / Track files with .corrected
    if[0<count r`corrected;
      filesWithDiffs:filesWithDiffs,enlist file];

    results:results,enlist r;
    i:i+1];

  / Collect all errors for --listci
  allErrors:raze results`errors;
  `results`totalPassed`totalFailed`totalFiles`failedFiles`filesWithDiffs`allErrors!(results;totalPassed;totalFailed;totalFiles;failedFiles;filesWithDiffs;allErrors)}

/ ============================================================================
/ IDE Diff Processing
/ ============================================================================

/ Get diff command for platform
getDiffCmd:{
  dt:@[getenv;"QDUST_DIFF_TOOL";{""}];
  if[0<count dt;:dt];
  os:first system"uname";
  $[os~"Darwin";"open -W -a FileMerge";
    os~"Linux";"meld";
    "diff"]}

/ Launch IDE diff for a file, wait for completion
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

/ Process diffs one at a time with optional rerun
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
/ Output
/ ============================================================================

/ Pad string to width
pad:{[s;w] s,(w-count s)#" "}

/ Get just filename from path
basename:{[p] s:last"/"vs p; $[0<count s;s;p]}

/ Print CI-clickable error links
printCiLinks:{[summary]
  if[0=count summary`allErrors;:()];
  -1"\nCI Error Links:";
  i:0;
  while[i<count summary`allErrors;
    -1 summary[`allErrors]i;
    i:i+1]}

printSummary:{[summary]
  / Condensed grid format
  -1"\nResults:";
  fnames:basename each summary[`results][`file];
  maxLen:2+max count each fnames;
  i:0;
  while[i<count summary`results;
    r:summary[`results]i;
    fn:basename r`file;
    status:$[r`success;
      string[r`passed]," passed";
      string[r`passed]," passed, ",string[r`failed]," failed"];
    -1"  ",pad[fn,":";maxLen],status;
    i:i+1];
  -1"";
  -1"Total: ",string[summary`totalPassed]," passed",$[0<summary`totalFailed;", ",string[summary`totalFailed]," failed";""];
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
/ Promote All
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

/ ============================================================================
/ Commands
/ ============================================================================

cmdTest:{[target]
  files:resolveTarget target;
  if[0=count files;exit 1];

  / Single file - run qdust1 and capture output via temp file
  if[1=count files;
    file:first files;
    qPath:scriptDir[],"/qdust1.q";
    flags:$[junit;"--junit ";json;"--json ";""];
    flags:flags,$[errorsOnly;"--errors-only ";""];
    flags:flags,$[listci;"--listci ";""];
    flags:flags,$[autoMergeNew;"--auto-merge-new ";""];
    tmpf:"/tmp/qdust_single_",string[`int$.z.t],".txt";
    shf:"/tmp/qdust_single_cmd.sh";
    (hsym`$shf)0:enlist"q ",qPath," ",flags,"test \"",file,"\" > ",tmpf," 2>&1";
    @[system;"bash ",shf;{}];
    output:@[read0;hsym`$tmpf;enlist""];
    @[system;"rm -f ",tmpf," ",shf;{}];
    {-1 x}each output;
    corrFile:file,".corrected";
    exit $[()~key hsym`$corrFile;0;1]];

  / Multiple files - use batch mode unless listci needs full output
  -1"Found ",string[count files]," test file(s)\n";
  summary:runAllFiles[files;not listci];
  $[json;printJsonSummary summary;printSummary summary];

  / Print CI-clickable links if requested
  if[listci;printCiLinks summary];

  / IDE diff processing for multiple files
  if[(diffMode~`ide)&launchDiff&(0<count summary`filesWithDiffs);
    processDiffs summary`filesWithDiffs];

  exit $[0=summary`totalFailed;0;1]}

cmdPromote:{[target]
  $[isPattern target;
    [pat:$[target like"*.q";(-2_target),".q.corrected";
           target like"*.t";(-2_target),".t.corrected";
           target,".corrected"];
     n:promoteByPattern pat;
     exit $[0<n;0;1]];
    isDir target;
    [n:promoteAll target;exit $[0<n;0;1]];
    [qPath:scriptDir[],"/qdust1.q";
     cmd:"q ",qPath," promote ",target;
     @[system;cmd;{}];
     exit 0]]}

/ Promote files matching pattern
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

/ Update .gitignore with qdust patterns
cmdGitignore:{
  giPath:".gitignore";
  patterns:("*.corrected";"*.failed");
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

/ Check for stale .corrected/.failed files (CI pre-check)
cmdCheck:{[dir]
  corrCmd:"find ",dir," -name \"*.corrected\" 2>/dev/null";
  failCmd:"find ",dir," -name \"*.failed\" 2>/dev/null";
  corrFiles:system corrCmd;
  failFiles:system failCmd;

  corrFiles:corrFiles where 0<count each corrFiles;
  failFiles:failFiles where 0<count each failFiles;

  total:(count corrFiles)+count failFiles;

  if[0=total;
    -1"OK: No .corrected or .failed files found";
    exit 0];

  -1"ERROR: Found ",string[total]," stale file(s)";
  -1"";

  if[0<count corrFiles;
    -1".corrected files (run 'qdust promote' or fix tests):";
    {-1"  ",x} each corrFiles];

  if[0<count failFiles;
    -1".failed files (fix load errors):";
    {-1"  ",x} each failFiles];

  -1"";
  -1"These indicate uncommitted test changes or errors.";
  exit 1}

help:{
  -1"qdust - Multi-file Q/K Expect Test Runner";
  -1"";
  -1"Usage:";
  -1"  q qdust.q test                   Test all .q/.t files in current directory";
  -1"  q qdust.q test <dir>             Test all .q/.t files in directory";
  -1"  q qdust.q test <file.q>          Test single file";
  -1"  q qdust.q test <pattern>         Test files matching pattern (recursive)";
  -1"  q qdust.q promote <dir>          Promote all .corrected files in directory";
  -1"  q qdust.q promote <file.q>       Promote single file";
  -1"  q qdust.q promote <pattern>      Promote matching .corrected files";
  -1"  q qdust.q check [dir]            Fail if .corrected/.failed files exist (CI)";
  -1"  q qdust.q gitignore              Add *.corrected and *.failed to .gitignore";
  -1"";
  -1"Options:";
  -1"  --json                          Output in JSON format";
  -1"  --junit                         Output in JUnit XML format (for CI)";
  -1"  --errors-only                   Show only errors, not full output";
  -1"  --listci                        CI-clickable error format";
  -1"  --nodiff                        Summary only, no diff output";
  -1"  --condiff                       Console diff (default)";
  -1"  --idediff                       Open IDE diff tool";
  -1"  --launch-diff                   Launch IDE diff for each file with diffs";
  -1"  --no-launch-diff                Don't launch IDE diff";
  -1"  --rerun-after-diff              Rerun tests after diff tool closes";
  -1"  --no-rerun-after-diff           Don't rerun after diff";
  -1"  --auto-merge-new                Auto-promote if only new tests (no changes)";
  -1"  --no-auto-merge-new             Require manual review for all (default)";
  -1"";
  -1"Environment:";
  -1"  QDUST_DIFF                       Diff tool command (e.g. \"code --diff\", \"idea diff\")";
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
  -1"  q qdust.q --idediff --rerun-after-diff test tests/";
  -1"  # Runs all tests, then opens diff tool for each failure.";
  -1"  # After closing diff tool, reruns that file's tests.";
  -1"  # If pass, continues to next file. If fail, shows result.";
  exit 0}

/ ============================================================================
/ Main
/ ============================================================================

main:{
  args:.z.x;

  initSettings[];

  / Parse flags
  i:0;
  while[i<count args;
    $[args[i]~"--json";json::1b;
      args[i]~"--junit";junit::1b;
      args[i]~"--errors-only";errorsOnly::1b;
      args[i]~"--listci";listci::1b;
      args[i]in("-v";"--verbose");verbose::1b;
      args[i]~"--nodiff";diffMode::`none;
      args[i]~"--condiff";diffMode::`console;
      args[i]~"--idediff";diffMode::`ide;
      args[i]~"--launch-diff";launchDiff::1b;
      args[i]~"--no-launch-diff";launchDiff::0b;
      args[i]~"--rerun-after-diff";rerunAfterDiff::1b;
      args[i]~"--no-rerun-after-diff";rerunAfterDiff::0b;
      args[i]~"--auto-merge-new";autoMergeNew::1b;
      args[i]~"--no-auto-merge-new";autoMergeNew::0b;
      ()];
    i:i+1];

  / Remove flags
  args:args where not(args like"-*")|(args like"--*");

  cmd:$[0<count args;args 0;""];
  target:$[1<count args;args 1;"."];

  $[cmd~"test";cmdTest target;
    cmd~"promote";cmdPromote target;
    cmd~"check";cmdCheck target;
    cmd~"gitignore";cmdGitignore[];
    help[]]}

\d .

/ Run if invoked from command line
if[0<count .z.x;.qd.main[]]
