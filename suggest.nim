#
#
#            Aporia - Nimrod IDE
#        (c) Copyright 2011 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import 
  gtk2, gdk2, glib2,
  strutils, osproc, os,
  utils

when not defined(os.findExe): 
  proc findExe*(exe: string): string = 
    ## returns "" if the exe cannot be found
    result = addFileExt(exe, os.exeExt)
    if ExistsFile(result): return
    var path = os.getEnv("PATH")
    for candidate in split(path, pathSep): 
      var x = candidate / result
      if ExistsFile(x): return x
    result = ""

proc addSuggestItem*(win: var MainWin, name: string, markup: String,
                     tooltipText: string, color: String = "#000000") =
  var iter: TTreeIter
  var listStore = cast[PListStore](win.suggest.TreeView.getModel())
  listStore.append(addr(iter))
  listStore.set(addr(iter), 0, name, 1, markup, 2, color, 3, tooltipText, -1)

proc addSuggestItem(win: var MainWin, item: TSuggestItem) =
  # TODO: Escape tooltip text for pango markup.
  win.addSuggestItem(item.nmName, "<b>$1</b>" % [item.nmName], item.nimType)

proc getIterGlobalCoords(iter: PTextIter, tab: Tab):
    tuple[x, y: int32] =
  # Calculate the location of the suggest dialog.
  var iterLoc: TRectangle
  tab.sourceView.getIterLocation(iter, addr(iterLoc))

  var winX, winY: gint
  tab.sourceView.bufferToWindowCoords(TEXT_WINDOW_WIDGET, iterLoc.x, iterLoc.y,
                                     addr(winX), addr(winY))
  
  var mainGWin = tab.sourceView.getWindow(TEXT_WINDOW_WIDGET)
  var mainLocX, mainLocY: gint
  discard mainGWin.getOrigin(addr(mainLocX), addr(mainLocY))
  
  # - Get the size of the left window(Line numbers) too.
  var leftGWin = tab.sourceView.getWindow(TEXT_WINDOW_LEFT)
  var leftWidth, leftHeight: gint
  {.warning: "get_size is deprecated, get_width should be used".}
  # TODO: This is deprecated, GTK version 2.4 has get_width/get_height
  leftGWin.getSize(addr(leftWidth), addr(leftHeight))

  return (mainLocX + leftWidth + iterLoc.x, mainLocY + winY + iterLoc.height)

proc moveSuggest*(win: var MainWin, start: PTextIter, tab: Tab) =
  var (x, y) = getIterGlobalCoords(start, tab)
  
  win.suggest.dialog.move(x, y)

proc doMoveSuggest*(win: var MainWin) =
  var current = win.SourceViewTabs.getCurrentPage()
  var tab     = win.Tabs[current]
  var start: TTextIter
  # Get the iter at the cursor position.
  tab.buffer.getIterAtMark(addr(start), tab.buffer.getInsert())
  moveSuggest(win, addr(start), tab)

proc execNimSuggest(file, addToPath: string, line: int, column: int): 
    seq[TSuggestItem] =
  result = @[]
  echo(findExe("nimrod") & 
                " idetools --path:$4 --path:$5 --track:$1,$2,$3 --suggest $1" % 
                [file, $(line+1), $column, getTempDir(), addToPath])
  var output = execProcess(findExe("nimrod") & 
                " idetools --path:$4 --path:$5 --track:$1,$2,$3 --suggest $1" % 
                [file, $(line+1), $column, getTempDir(), addToPath])

  for line in splitLines(output):
    #echo(repr(line))
    if line.startswith("sug\t"):
      var s = line.split('\t')
      if s.len == 7:
        var item: TSuggestItem
        item.nodeType = s[1]
        item.name = s[2]
        item.nimType = s[3]
        item.file = s[4]
        item.line = int32(s[5].parseInt())
        item.col = int32(s[6].parseInt())
        
        # Get the name without the module name in front of it.
        var dots = item.name.split('.')
        if dots.len() == 2:
          item.nmName = item.name[dots[0].len()+1.. -1]
        else:
          echo("[Suggest] Unknown module name for ", item.name)
          #continue
          item.nmName = item.name
        
        result.add(item)

proc populateSuggest*(win: var MainWin, start: PTextIter, tab: Tab): bool = 
  ## Populates the suggestDialog with items, returns true if at least one item 
  ## has been added.
  if tab.filename == "": return False
  var currentTabSplit = splitFile(tab.filename)
  
  # Save tabs that are in the same directory as the file being suggested to /tmp
  for t in items(win.Tabs):
    if t.filename != "" and t.filename.splitFile.dir == currentTabSplit.dir:
      var f: TFile
      var fileSplit = splitFile(t.filename)
      echo("Saving ", getTempDir() / fileSplit.name & fileSplit.ext)
      if f.open(getTempDir() / fileSplit.name & fileSplit.ext, fmWrite):
        # Save everything.
        # - Get the text from the TextView.
        var startIter: TTextIter
        t.buffer.getStartIter(addr(startIter))
        
        var endIter: TTextIter
        t.buffer.getEndIter(addr(endIter))
        
        var text = t.buffer.getText(addr(startIter), addr(endIter), False)
        
        # - Save it.
        f.write(text)
      else:
        echo("[Warning] Unable to save one or more files, suggest won't work.")
        return False
      f.close()
  
  # Copy over nimrod.cfg if it exists to /tmp
  if existsFile(currentTabSplit.dir / "nimrod".addFileExt("cfg")):
    copyFile(currentTabSplit.dir / "nimrod".addFileExt("cfg"), 
             getTempDir() / "nimrod".addFileExt("cfg"))
  
  var file = getTempDir() / currentTabSplit.name & ".nim"
  win.suggest.items = execNimSuggest(file, splitFile(tab.filename).dir,
                                     start.getLine(),
                                     start.getLineOffset())
  win.suggest.allitems = win.suggest.items
  
  if win.suggest.items.len == 0:
    echo("[Warning] No items found for suggest")
    return False
  
  # Remove the temporary file.
  #removeFile(file)
  
  for i in items(win.suggest.items):
    win.addSuggestItem(i)

  win.suggest.currentFilter = ""

  return True

proc clear*(suggest: var TSuggestDialog) =
  var TreeModel = suggest.TreeView.getModel()
  # TODO: Why do I have to cast it? Why can't I just do PListStore(TreeModel)?
  cast[PListStore](TreeModel).clear()
  suggest.items = @[]
  suggest.allItems = @[]

proc show*(suggest: var TSuggestDialog) =
  if not suggest.shown and suggest.items.len() > 0:
    var selection = suggest.treeview.getSelection()  
    var selectedPath = tree_path_new_first()
    selection.selectPath(selectedPath)
    suggest.treeview.scroll_to_cell(selectedPath, nil, False, 0.5, 0.5)
  
    suggest.shown = true
    suggest.dialog.show()

proc hide*(suggest: var TSuggestDialog) =
  if suggest.shown:
    suggest.shown = false
    suggest.dialog.hide()
    # Hide the tooltip too.
    suggest.tooltip.hide()

proc filterSuggest*(win: var MainWin) =
  ## Filters the current suggest items after whatever is behind the cursor.
  # Get text before the cursor, up to a dot.
  var current = win.SourceViewTabs.getCurrentPage()
  var tab     = win.Tabs[current]
  var cursor: TTextIter
  # Get the iter at the cursor position.
  tab.buffer.getIterAtMark(addr(cursor), tab.buffer.getInsert())
  
  # Search backwards for a dot.
  var startMatch: TTextIter
  var endMatch: TTextIter
  var matched = (addr(cursor)).backwardSearch(".", TEXT_SEARCH_TEXT_ONLY,
                                addr(startMatch), addr(endMatch), nil)
  assert(matched)
  var text = (addr(endMatch)).getText(addr(cursor))
  echo("[Suggest] Filtering ", text)
  win.suggest.currentFilter = normalize($text)
  # Filter the items.
  var allItems = win.suggest.allItems
  win.suggest.clear()
  var newItems: seq[TSuggestItem] = @[]
  for i in items(allItems):
    if normalize(i.nmName).startsWith(normalize($text)):
      newItems.add(i)
      win.addSuggestItem(i)
  win.suggest.items = newItems
  win.suggest.allItems = allItems

  # Hide the tooltip
  win.suggest.tooltip.hide()

  if win.suggest.items.len() == 0: win.suggest.hide()

proc doSuggest*(win: var MainWin) =
  var current = win.SourceViewTabs.getCurrentPage()
  var tab     = win.Tabs[current]
  var start: TTextIter
  # Get the iter at the cursor position.
  tab.buffer.getIterAtMark(addr(start), tab.buffer.getInsert())

  if win.populateSuggest(addr(start), tab):
    win.suggest.show()
    moveSuggest(win, addr(start), tab)
    #win.Tabs[current].sourceView.grabFocus()
    #assert(win.Tabs[current].sourceView.isFocus())
    #win.w.present()
  else: win.suggest.hide()

proc insertSuggestItem*(win: var MainWin, index: int) =
  var name = win.suggest.items[index].nmName
  # Remove the part that was already typed
  if win.suggest.currentFilter != "":
    assert(normalize(name).startsWith(win.suggest.currentFilter))
    name = name[win.suggest.currentFilter.len() .. -1]
  
  # We have the name of the item. Now insert it into the TextBuffer.
  var currentTab = win.SourceViewTabs.getCurrentPage()
  win.Tabs[currentTab].buffer.insertAtCursor(name, int32(len(name)))
  
  # Now hide the suggest dialog and clear the items.
  win.suggest.hide()
  win.suggest.clear()

proc showTooltip*(win: var MainWin, tab: Tab, markup: string,
                  selectedPath: PTreePath) =
  win.suggest.tooltipLabel.setMarkup(markup)
  var cursor: TTextIter
  # Get the iter at the cursor position.
  tab.buffer.getIterAtMark(addr(cursor), tab.buffer.getInsert())
  # Get the location where to show the tooltip.
  var (x, y) = getIterGlobalCoords(addr(cursor), tab)
  # Get the width of the suggest dialog to move the tooltip out of the way.
  var width: gint
  win.suggest.dialog.getSize(addr(width), nil)
  x += width

  # Find the position of the selected tree item.
  var cellArea: TRectangle
  win.suggest.treeview.getCellArea(selectedPath, nil, addr(cellArea))
  y += cellArea.y

  win.suggest.tooltip.move(x, y)
  win.suggest.tooltip.show()

  win.suggest.tooltip.resize(1, 1) # Reset the window size. Kinda hackish D:
  
  tab.sourceView.grabFocus()
  assert(tab.sourceView.isFocus())
  win.w.present()

# -- Signals
proc TreeView_RowActivated(tv: PTreeView, path: PTreePath, 
            column: PTreeViewColumn, win: ptr MainWin) =
  var index = path.getIndices()[]
  if win.suggest.items.len() > index:
    win[].insertSuggestItem(index)

proc TreeView_SelectChanged(selection: PTreeSelection, win: ptr MainWin) =
  var selectedIter: TTreeIter
  var TreeModel: PTreeModel
  if selection.getSelected(addr(TreeModel), addr(selectedIter)):
    # Get current tab(For tooltip)
    var current = win.SourceViewTabs.getCurrentPage()
    var tab     = win.Tabs[current]
    var selectedPath = TreeModel.getPath(addr(selectedIter))
    var index = selectedPath.getIndices()[]
    if win.suggest.items.len() > index:
      if win.suggest.shown:
        win[].showTooltip(tab, win.suggest.items[index].nimType, selectedPath)

proc onFocusIn(widget: PWidget, ev: PEvent, win: ptr MainWin) =
  win.w.present()
  var current = win.SourceViewTabs.getCurrentPage()
  win.Tabs[current].sourceView.grabFocus()
  assert(win.Tabs[current].sourceView.isFocus())

# -- GUI
proc createSuggestDialog*(win: var MainWin) =
  ## Creates the suggest dialog, it does not show it.
  
  #win.suggest.dialog = dialogNew()
  win.suggest.dialog = windowNew(0)

  var vbox = vboxNew(False, 0)
  win.suggest.dialog.add(vbox)
  vbox.show()

  # TODO: Destroy actionArea?
  # Destroy the separator, don't need it.
  #win.suggest.dialog.separator.destroy()
  #win.suggest.dialog.separator = nil
  #win.suggest.dialog.actionArea.hide()
  #win.suggest.dialog.vbox.remove(win.suggest.dialog.actionArea)
  #echo(win.suggest.dialog.vbox.spacing)
  
  # Properties
  win.suggest.dialog.setDefaultSize(250, 150)
  
  win.suggest.dialog.setTransientFor(win.w)
  win.suggest.dialog.setDecorated(False)
  win.suggest.dialog.setSkipTaskbarHint(True)
  discard win.suggest.dialog.signalConnect("focus-in-event",
      SIGNAL_FUNC(onFocusIn), addr(win))
  
  # TreeView & TreeModel
  # -- ScrolledWindow
  var scrollWindow = scrolledWindowNew(nil, nil)
  scrollWindow.setPolicy(POLICY_AUTOMATIC, POLICY_AUTOMATIC)
  vbox.packStart(scrollWindow, True, True, 0)
  scrollWindow.show()
  # -- TreeView
  win.suggest.treeView = treeViewNew()
  win.suggest.treeView.setHeadersVisible(False)
  #win.suggest.treeView.setHasTooltip(true)
  #win.suggest.treeView.setTooltipColumn(3)
  scrollWindow.add(win.suggest.treeView)
  
  discard win.suggest.treeView.signalConnect("row-activated",
              SIGNAL_FUNC(TreeView_RowActivated), addr(win))
              
  var selection = win.suggest.treeview.getSelection()
  discard selection.gsignalConnect("changed",
              GCallback(TreeView_SelectChanged), addr(win))
  
  var textRenderer = cellRendererTextNew()
  # Renderer is number 0. That's why we count from 1.
  var textColumn   = treeViewColumnNewWithAttributes("Title", textRenderer,
                     "markup", 1, "foreground", 2, nil)
  discard win.suggest.treeView.appendColumn(textColumn)
  # -- ListStore
  # There are 3 attributes. The renderer is counted. Last is the tooltip text.
  var listStore = listStoreNew(4, TypeString, TypeString, TypeString, TypeString)
  assert(listStore != nil)
  win.suggest.treeview.setModel(liststore)
  win.suggest.treeView.show()
  
  # -- Append some items.
  #win.addSuggestItem("Test!", "<b>Tes</b>t!")
  #win.addSuggestItem("Test2!", "Test2!", "#ff0000")
  #win.addSuggestItem("Test3!")
  win.suggest.items = @[]
  win.suggest.allItems = @[]
  #win.suggest.dialog.show()

  # -- Tooltip
  win.suggest.tooltip = windowNew(gtk2.WINDOW_TOPLEVEL)
  win.suggest.tooltip.setTypeHint(WINDOW_TYPE_HINT_TOOLTIP)
  win.suggest.tooltip.setTransientFor(win.w)
  win.suggest.tooltip.setSkipTaskbarHint(True)
  win.suggest.tooltip.setDecorated(False)
  
  discard win.suggest.tooltip.signalConnect("focus-in-event",
    SIGNAL_FUNC(onFocusIn), addr(win))
  
  var tpVBox = vboxNew(false, 0)
  win.suggest.tooltip.add(tpVBox)
  tpVBox.show()
  
  var tpHBox = hboxNew(false, 0)
  tpVBox.packStart(tpHBox, false, false, 3)
  tpHBox.show()
  
  win.suggest.tooltipLabel = labelNew("")
  win.suggest.tooltipLabel.setLineWrap(true)
  tpHBox.packStart(win.suggest.tooltipLabel, false, false, 3)
  win.suggest.tooltipLabel.show()
  
when isMainModule:
  var result = execNimSuggest("aporia.nim", 633, 7)
  
  echo repr(result)






