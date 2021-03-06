## This module contains functions which deal with running processes, such as the Nimrod process.
## There are also some functions for gathering errors as given by the nimrod compiler and putting them into the error list.

import pegs, times, osproc, streams, parseutils, strutils, re
import gtk2, glib2
import utils


var win*: ptr utils.MainWin

# Threading channels
var execThrTaskChan: TChannel[TExecThrTask]
execThrTaskChan.open()
var execThrEventChan: TChannel[TExecThrEvent]
execThrEventChan.open()
# Threading channels END

var
  pegLineError = peg"{[^(]*} '(' {\d+} ', ' \d+ ') Error:' \s* {.*}"
  pegLineWarning = peg"{[^(]*} '(' {\d+} ', ' \d+ ') ' ('Warning:'/'Hint:') \s* {.*}"
  pegOtherError = peg"'Error:' \s* {.*}"
  pegSuccess = peg"'Hint: operation successful'.*"
  pegOtherHint = peg"'Hint: '.*"
  reLineMessage = re".+\(\d+,\s\d+\)"
  pegLineInfo = peg"{[^(]*} '(' {\d+} ', ' \d+ ') Info:' \s* {.*}"

proc `$`(theType: TErrorType): string =
  case theType
  of TETError: result = "Error"
  of TETWarning: result = "Warning"

proc clearErrors*() =
  var TreeModel = win.errorListWidget.getModel()
  # TODO: Why do I have to cast it? Why can't I just do PListStore(TreeModel)?
  cast[PListStore](TreeModel).clear()
  win.tempStuff.errorList = @[]

proc addError*(theType: TErrorType, desc, file, line, col: string) =
  var ls = cast[PListStore](win.errorListWidget.getModel())
  var iter: TTreeIter
  ls.append(addr(iter))
  ls.set(addr(iter), 0, $theType, 1, desc, 2, file, 3, line, 4, col, -1)
  
  var newErr: TError
  newErr.kind = theType
  newErr.desc = desc
  newErr.file = file
  newErr.line = line
  newErr.column = col
  win.tempStuff.errorList.add(newErr)

proc parseError(err: string, 
            res: var tuple[theType: TErrorType, desc, file, line, col: string]) =
  ## Parses a line like:
  ##   ``a12.nim(1, 3) Error: undeclared identifier: 'asd'``
  ##
  ## or: 
  ##
  ## lib/system.nim(686, 5) Error: type mismatch: got (string, int literal(5))
  ## but expected one of: 
  ## <(x: pointer, y: pointer): bool
  ## <(x: UIntMax32, y: UIntMax32): bool
  ## <(x: int32, y: int32): bool
  ## <(x: float, y: float): bool
  ## <(x: T, y: T): bool
  ## <(x: int16, y: int16): bool
  ## <(x: ordinal[T], y: ordinal[T]): bool
  ## <(x: int, y: int): bool
  ## <(x: ordinal[T]): T
  ## <(x: ref T, y: ref T): bool
  ## <(x: ptr T, y: ptr T): bool
  ## <(x: char, y: char): bool
  ## <(x: string, y: string): bool
  ## <(x: bool, y: bool): bool
  ## <(x: set[T], y: set[T]): bool
  ## <(x: int64, y: int64): bool
  ## <(x: uint64, y: uint64): bool
  ## <(x: int8, y: int8): bool
  var i = 0
  res.file = ""
  i += parseUntil(err, res.file, '(', i)
  inc(i) # Skip (
  res.line = ""
  var lineInt = -1
  i += parseInt(err, lineInt, i)
  res.line = $lineInt
  inc(i) # Skip ,
  i += skipWhitespace(err, i)
  res.col = ""
  var colInt = -1
  i += parseInt(err, colInt, i)
  res.col = $colInt
  inc(i) # Skip )
  i += skipWhitespace(err, i)
  var theType = ""
  i += parseUntil(err, theType, ':', i)
  case normalize(theType)
  of "error", "info":
    res.theType = TETError
  of "hint", "warning":
    res.theType = TETWarning
  else:
    echo(theType)
    assert(false)
  inc(i) # Skip :
  i += skipWhitespace(err, i)
  res.desc = err.substr(i, err.len()-1)

proc execProcAsync*(cmd: string, mode: TExecMode, ifSuccess: string = "")
proc printProcOutput(line: string) =
  ## This shouldn't have to worry about receiving broken up errors (into new lines)
  ## continuous errors should be received, errors which span multiple lines
  ## should be received as one continuous message.
  echod("Printing: ", line.repr)
  template paErr(): stmt =
    var parseRes: tuple[theType: TErrorType, desc, file, line, col: string]
    parseError(line, parseRes)
    addError(parseRes.theType, parseRes.desc,
             parseRes.file, parseRes.line, parseRes.col)

  # Colors
  var normalTag = createColor(win.outputTextView, "normalTag", "#3d3d3d")
  var errorTag = createColor(win.outputTextView, "errorTag", "red")
  var warningTag = createColor(win.outputTextView, "warningTag", "darkorange")
  var successTag = createColor(win.outputTextView, "successTag", "darkgreen")
  
  case win.tempStuff.execMode:
  of ExecNimrod:
    if line =~ pegLineError / pegOtherError / pegLineInfo:
      win.outputTextView.addText(line & "\n", errorTag)
      paErr()
      win.tempStuff.compileSuccess = false
    elif line =~ pegSuccess:
      win.outputTextView.addText(line & "\n", successTag)
      win.tempStuff.compileSuccess = true
    elif line =~ pegLineWarning:
      win.outputTextView.addText(line & "\n", warningTag)
      paErr()
    else:
      win.outputTextView.addText(line & "\n", normalTag)
  of ExecRun, ExecCustom:
    win.outputTextView.addText(line & "\n", normalTag)
  of ExecNone:
    assert(false)

proc peekProcOutput*(dummy: pointer): bool =
  result = True
  if win.tempStuff.execMode != ExecNone:
    var events = execThrEventChan.peek()
    
    if epochTime() - win.tempStuff.lastProgressPulse >= 0.1:
      win.bottomProgress.pulse()
      win.tempStuff.lastProgressPulse = epochTime()
    if events > 0:
      var successTag = createColor(win.outputTextView, "successTag",
                                   "darkgreen")
      var errorTag = createColor(win.outputTextView, "errorTag", "red")
      for i in 0..events-1:
        var event: TExecThrEvent = execThrEventChan.recv()
        case event.typ
        of EvStarted:
          win.tempStuff.execProcess = event.p
        of EvRecv:
          event.line = event.line.strip()
          if win.tempStuff.execMode == execNimrod:
            if event.line != "":
              echod("Line is: " & event.line.repr)
            if event.line == "" or event.line.startsWith(pegSuccess) or
                event.line =~ pegOtherHint:
              echod(1)
              if win.tempStuff.errorMsgStarted:
                win.tempStuff.errorMsgStarted = false
                printProcOutput(win.tempStuff.compilationErrorBuffer.strip())
                win.tempStuff.compilationErrorBuffer = ""
              if event.line != "":
                printProcOutput(event.line)
            elif event.line.startsWith(reLineMessage):
              echod(2)
              if not win.tempStuff.errorMsgStarted:
                echod(2.1)
                win.tempStuff.errorMsgStarted = true
                win.tempStuff.compilationErrorBuffer.add(event.line & "\n")
              elif win.tempStuff.compilationErrorBuffer != "":
                echod(2.2)
                printProcOutput(win.tempStuff.compilationErrorBuffer.strip())
                win.tempStuff.compilationErrorBuffer = ""
                win.tempStuff.errorMsgStarted = false
                printProcOutput(event.line)
              else:
                printProcOutput(event.line)
            else:
              echod(3)
              if win.tempStuff.errorMsgStarted:
                win.tempStuff.compilationErrorBuffer.add(event.line & "\n")
              else:
                printProcOutput(event.line)
          else:
            if event.line != "":
              printProcOutput(event.line)
        of EvStopped:
          echod("[Idle] Process has quit")
          if win.tempStuff.compilationErrorBuffer.len() > 0:
            printProcOutput(win.tempStuff.compilationErrorBuffer)
          
          win.tempStuff.execMode = ExecNone
          win.bottomProgress.hide()
          
          if event.exitCode == QuitSuccess:
            win.outputTextView.addText("> Process terminated with exit code " & 
                                             $event.exitCode & "\n", successTag)
          else:
            win.outputTextView.addText("> Process terminated with exit code " & 
                                             $event.exitCode & "\n", errorTag)
          
          # Execute another process in queue (if any)
          if win.tempStuff.ifSuccess != "" and win.tempStuff.compileSuccess:
            echod("Starting new process?")
            execProcAsync(win.tempStuff.ifSuccess, ExecRun)
  else:
    echod("idle proc exiting")
    return false

proc execProcAsync*(cmd: string, mode: TExecMode, ifSuccess: string = "") =
  ## This function executes a process in a new thread, using only idle time
  ## to add the output of the process to the `outputTextview`.
  assert(win.tempStuff.execMode == ExecNone)
  
  # Reset some things; and set some flags.
  echod("Spawning new process.")
  win.tempStuff.ifSuccess = ifSuccess
  # Execute the process
  echo(cmd)
  var task: TExecThrTask
  task.typ = ThrRun
  task.command = cmd
  execThrTaskChan.send(task)
  win.tempStuff.execMode = mode
  # Output
  var normalTag = createColor(win.outputTextView, "normalTag", "#3d3d3d")
  win.outputTextView.addText("> " & cmd & "\n", normalTag)
  
  # Add a function which will be called when the UI is idle.
  win.tempStuff.idleFuncId = gIdleAdd(peekProcOutput, nil)
  echod("gTimeoutAdd id = ", $win.tempStuff.idleFuncId)

  win.bottomProgress.show()
  win.bottomProgress.pulse()
  win.tempStuff.lastProgressPulse = epochTime()
  # Clear errors
  clearErrors()


template createExecThrEvent(t: TExecThrEventType, todo: stmt): stmt =
  ## Sends a thrEvent of type ``t``, does ``todo`` before sending.
  var event: TExecThrEvent
  event.typ = t
  todo
  execThrEventChan.send(event)

proc execThreadProc(){.thread.} =
  var p: PProcess
  var o: PStream
  var started = false
  while True:
    var tasks = execThrTaskChan.peek()
    if tasks == 0 and not started: tasks = 1
    if tasks > 0:
      for i in 0..tasks-1:
        var task: TExecThrTask = execThrTaskChan.recv()
        case task.typ
        of ThrRun:
          if not started:
            p = startCmd(task.command)
            createExecThrEvent(EvStarted):
              event.p = p
            o = p.outputStream
            started = true
          else:
            echod("[Thread] Process already running")
        of ThrStop:
          echod("[Thread] Stopping process.")
          p.terminate()
          started = false
          o.close()
          var exitCode = p.waitForExit()
          createExecThrEvent(EvStopped):
            event.exitCode = exitCode
          p.close()
    
    # Check if process exited.
    if started:
      if not p.running:
        echod("[Thread] Process exited.")
        if not o.atEnd:
          var line = ""
          while not o.atEnd:
            line = o.readLine()
            createExecThrEvent(EvRecv):
              event.line = line
        
        # Process exited.
        var exitCode = p.waitForExit()
        p.close()
        o.close()
        started = false
        createExecThrEvent(EvStopped):
          event.exitCode = exitCode
    
    if started:
      var line = o.readLine()
      createExecThrEvent(EvRecv):
        event.line = line

proc createProcessThreads*() =
  createThread[void](win.tempStuff.execThread, execThreadProc)
