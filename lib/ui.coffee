_ = require 'underscore-plus'
{Point, Range, CompositeDisposable, Emitter} = require 'atom'
{
  getNextAdjacentPaneForPane
  getPreviousAdjacentPaneForPane
  splitPane
  isActiveEditor
  setBufferRow
  isTextEditor
  isNarrowEditor
  paneForItem
  isDefinedAndEqual
  injectLineHeader
  ensureNoModifiedFileForChanges
  ensureNoConflictForChanges
  isNormalItem
  getItemsWithHeaders
  getItemsWithoutUnusedHeader
} = require './utils'
settings = require './settings'
Grammar = require './grammar'
getFilterSpecForQuery = require './get-filter-spec-for-query'
Highlighter = require './highlighter'
ControlBar = require './control-bar'
Items = require './items'
ItemIndicator = require './item-indicator'

module.exports =
class Ui
  # Ui static
  # -------------------------
  @uiByEditor: new Map()
  @unregister: (ui) ->
    @uiByEditor.delete(ui.editor)
    @updateWorkspaceClassList()

  @register: (ui) ->
    @uiByEditor.set(ui.editor, ui)
    @updateWorkspaceClassList()

  @get: (editor) ->
    @uiByEditor.get(editor)

  @updateWorkspaceClassList: ->
    atom.views.getView(atom.workspace).classList.toggle('has-narrow', @uiByEditor.size)

  @getNextTitleNumber: ->
    numbers = [0]
    @uiByEditor.forEach (ui) ->
      numbers.push(ui.titleNumber)
    Math.max(numbers...) + 1

  # Ui.prototype
  # -------------------------
  autoPreview: null
  autoPreviewOnQueryChange: null

  inPreview: false
  ignoreChange: false
  ignoreCursorMove: false
  destroyed: false
  cachedItems: null # Used to cache result
  lastQuery: ''
  modifiedState: null
  readOnly: false
  protected: false
  excludedFiles: null

  onDidMoveToPrompt: (fn) -> @emitter.on('did-move-to-prompt', fn)
  emitDidMoveToPrompt: -> @emitter.emit('did-move-to-prompt')

  onDidMoveToItemArea: (fn) -> @emitter.on('did-move-to-item-area', fn)
  emitDidMoveToItemArea: -> @emitter.emit('did-move-to-item-area')

  onDidRefresh: (fn) -> @emitter.on('did-refresh', fn)
  emitDidRefresh: -> @emitter.emit('did-refresh')
  onWillRefresh: (fn) -> @emitter.on('will-refresh', fn)
  emitWillRefresh: -> @emitter.emit('will-refresh')

  onWillRefreshManually: (fn) -> @emitter.on('will-refresh-manually', fn)
  emitWillRefreshManually: -> @emitter.emit('will-refresh-manually')

  onDidStopRefreshing: (fn) -> @emitter.on('did-stop-refreshing', fn)
  emitDidStopRefreshing: ->
    # Debounced, fired after 100ms delay
    @_emitDidStopRefreshing ?= _.debounce((=> @emitter.emit('did-stop-refreshing')), 100)
    @_emitDidStopRefreshing()

  onDidPreview: (fn) -> @emitter.on('did-preview', fn)
  emitDidPreview: (event) -> @emitter.emit('did-preview', event)

  onDidConfirm: (fn) -> @emitter.on('did-confirm', fn)
  emitDidConfirm: (event) -> @emitter.emit('did-confirm', event)

  registerCommands: ->
    atom.commands.add @editorElement,
      'core:confirm': => @confirm()
      'core:move-up': (event) => @moveUpOrDown(event, 'previous')
      'core:move-down': (event) => @moveUpOrDown(event, 'next')

      'narrow:close': (event) => @narrowClose(event)

      'narrow-ui:confirm-keep-open': => @confirm(keepOpen: true)
      'narrow-ui:protect': => @toggleProtected()
      'narrow-ui:preview-item': => @preview()
      'narrow-ui:preview-next-item': => @previewNextItem()
      'narrow-ui:preview-previous-item': => @previewPreviousItem()
      'narrow-ui:toggle-auto-preview': => @toggleAutoPreview()
      'narrow-ui:move-to-prompt-or-selected-item': => @moveToPromptOrSelectedItem()
      'narrow-ui:move-to-prompt': => @moveToPrompt()
      'narrow-ui:start-insert': => @setReadOnly(false)
      'narrow-ui:stop-insert': => @setReadOnly(true)
      'narrow-ui:update-real-file': => @updateRealFile()
      'narrow-ui:exclude-file': => @excludeFile()
      'narrow-ui:clear-excluded-files': => @clearExcludedFiles()
      'narrow-ui:move-to-next-file-item': => @moveToNextFileItem()
      'narrow-ui:move-to-previous-file-item': => @moveToPreviousFileItem()
      'narrow-ui:toggle-search-whole-word': => @toggleSearchWholeWord()
      'narrow-ui:toggle-search-ignore-case': => @toggleSearchIgnoreCase()

  withIgnoreCursorMove: (fn) ->
    @ignoreCursorMove = true
    fn()
    @ignoreCursorMove = false

  withIgnoreChange: (fn) ->
    @ignoreChange = true
    fn()
    @ignoreChange = false

  isModified: ->
    @modifiedState

  setModifiedState: (state) ->
    return if state is @modifiedState

    # HACK: overwrite TextBuffer:isModified to return static state.
    # This state is used by tabs package to show modified icon on tab.
    @modifiedState = state
    @editor.buffer.isModified = -> state
    @editor.buffer.emitModifiedStatusChanged(state)

  toggleSearchWholeWord: ->
    @provider.toggleSearchWholeWord()
    @refresh(force: true)
    @updateControlBar(wholeWordButton: @provider.searchWholeWord)

  toggleSearchIgnoreCase: ->
    @provider.toggleSearchIgnoreCase()
    @refresh(force: true)
    @updateControlBar(ignoreCaseButton: @provider.searchIgnoreCase)

  toggleProtected: ->
    @protected = not @protected
    @itemIndicator.update({@protected})
    @updateControlBar({@protected})

  toggleAutoPreview: ->
    @autoPreview = not @autoPreview
    @updateControlBar({@autoPreview})
    if @autoPreview
      @preview()
    else
      @highlighter.clearLineMarker()

  setReadOnly: (readOnly) ->
    @readOnly = readOnly
    if @readOnly
      @editorElement.component?.setInputEnabled(false)
      @editorElement.classList.add('read-only')
      @vmpActivateNormalMode() if @vmpIsInsertMode()
    else
      @editorElement.component?.setInputEnabled(true)
      @editorElement.classList.remove('read-only')
      @vmpActivateInsertMode() if @vmpIsNormalMode()

  constructor: (@provider, {@query}={}) ->
    @query ?= ''
    @disposables = new CompositeDisposable
    @emitter = new Emitter
    @excludedFiles = []
    @autoPreview = @provider.getConfig('autoPreview')
    @autoPreviewOnQueryChange = @provider.getConfig('autoPreviewOnQueryChange')
    @highlighter = new Highlighter(this)

    # Special place holder item used to translate narrow-editor row to item row without mess.
    @itemAreaStart = Object.freeze(new Point(1, 0))

    # Setup narrow-editor
    # -------------------------
    @editor = atom.workspace.buildTextEditor(lineNumberGutterVisible: false)
    @titleNumber = @constructor.getNextTitleNumber()
    title = @provider.dashName + '-' + @titleNumber
    @editor.getTitle = -> title
    @editor.onDidDestroy(@destroy.bind(this))
    @editorElement = @editor.element
    @editorElement.classList.add('narrow', 'narrow-editor', @provider.dashName)

    @grammar = new Grammar(@editor, includeHeaderRules: not @provider.boundToSingleFile)
    @items = new Items(this)
    @itemIndicator = new ItemIndicator(@editor)

    @items.onDidChangeSelectedItem ({row}) =>
      @itemIndicator.update(row: row)

    if settings.get('autoShiftReadOnlyOnMoveToItemArea')
      @disposables.add @onDidMoveToItemArea =>
        @setReadOnly(true)

    # Depends on ui.grammar and commands bound to @editorElement, so have to come last
    @controlBar = new ControlBar(this, showSearchOption: @provider.showSearchOption)
    @constructor.register(this)

  getPaneToOpen: ->
    basePane = @provider.getPane()

    [direction, adjacentPanePreference] = @provider.getConfig('directionToOpen').split(':')

    pane = switch adjacentPanePreference
      when 'always-new-pane'
        null
      when 'never-use-previous-adjacent-pane'
        getNextAdjacentPaneForPane(basePane)
      else
        getNextAdjacentPaneForPane(basePane) ? getPreviousAdjacentPaneForPane(basePane)

    pane ? splitPane(basePane, split: direction)

  open: ({pending}={}) ->
    pending ?= false

    # When initial getItems() take very long time, it means refresh get delayed.
    # In this case, user see modified icon(mark) on tab.
    # Explicitly setting modified start here prevent this
    @setModifiedState(false)

    # [NOTE] When new item is activated, existing PENDING item is destroyed.
    # So existing PENDING narrow-editor is destroyed at this timing.
    # And PENDING narrow-editor's provider's editor have foucsed.
    # So pane.activate must be called AFTER activateItem
    pane = @getPaneToOpen()
    pane.activateItem(@editor, {pending})
    pane.activate()

    @grammar.activate()
    @insertQuery(@query)
    @controlBar.show()
    @moveToPrompt()

    @disposables.add(
      @registerCommands()
      @observeChange()
      @observeCursorMove()
      @observeStopChangingActivePaneItem()
    )

    @refresh().then =>
      if @provider.needAutoReveal()
        @syncToEditor(@provider.editor)
        @moveToBeginningOfSelectedItem()
        @preview()
      else if @query and @autoPreviewOnQueryChange
        @preview()

  observeStopChangingActivePaneItem: ->
    atom.workspace.onDidStopChangingActivePaneItem (item) =>
      if item isnt @editor
        # When item other than narrow-editor was activated,
        # No longer restore editor's state.
        # This guard is necessary since initial narrow-editor open fire this event.
        @provider.needRestoreEditorState = false
      return if not isTextEditor(item) or isNarrowEditor(item)
      return if paneForItem(item) is @getPane()
      @startSyncToEditor(item)

  getPane: ->
    paneForItem(@editor)

  isActive: ->
    isActiveEditor(@editor)

  focus: ->
    pane = @getPane()
    pane.activate()
    pane.activateItem(@editor)
    @preview() if @autoPreview

  focusPrompt: ->
    if @isActive() and @isAtPrompt()
      @activateProviderPane()
    else
      @focus() unless @isActive()
      @moveToPrompt()

  toggleFocus: ->
    if @isActive()
      @activateProviderPane()
    else
      @focus()

  activateProviderPane: ->
    if pane = @provider.getPane()
      pane.activate()
      if editor = pane.getActiveEditor()
        editor.scrollToCursorPosition()

  destroy: ->
    return if @destroyed

    @destroyed = true
    @constructor.unregister(this)
    @highlighter.destroy()
    @syncSubcriptions?.dispose()
    @disposables.dispose()
    @editor.destroy()
    @activateProviderPane()

    @controlBar.destroy()
    @provider?.destroy?()
    @items.destroy()
    @itemIndicator.destroy()

  # This function is mapped from `narrow:close`
  # To differentiate `narrow:close` for protected narrow-editor.
  # * Two purpose.
  # 1. So that don't close non-protected narrow-editor when narrow:close is
  #   invoked from protected narrow-editor
  # 2. To re-focus to caller editor for not interfering regular preview-then-close-by-ctrl-g flow.
  narrowClose: (event) ->
    if @protected
      event.stopImmediatePropagation()
      @insertQuery() # clear query
      @activateProviderPane()

  # Just setting cursor position works but it lost goalColumn when that row was skip item's row.
  moveUpOrDown: (event, direction) ->
    cursor = @editor.getLastCursor()
    row = cursor.getBufferRow()

    if (direction is 'next' and row is @editor.getLastBufferRow()) or
        (direction is 'previous' and @isPromptRow(row))
      # This is the command which override `core:move-up`, `core-move-down`
      # So when this command do work, it stop propagation, unless that case
      # this command do nothing and default behavior is still executed.
      ensureCursorIsOneColumnLeftFromEOL = @vmpIsNormalMode()
      event.stopImmediatePropagation()
      row = @items.findRowForNormalOrPromptItem(row, direction)
      setBufferRow(cursor, row, {ensureCursorIsOneColumnLeftFromEOL})

  # Even in movemnt not happens, it should confirm current item
  # This ensure next-item/previous-item always move to selected item.
  confirmItemForDirection: (direction) ->
    point = @provider.editor.getCursorBufferPosition()
    @items.selectItemInDirection(point, direction)
    @confirm(keepOpen: true, flash: true)

  nextItem: ->
    @confirmItemForDirection('next')

  previousItem: ->
    @confirmItemForDirection('previous')

  previewItemForDirection: (direction) ->
    rowForSelectedItem = @items.getRowForSelectedItem()
    if not @highlighter.hasLineMarker() and direction is 'next'
      # When initial invocation not cause preview(since initial query input was empty).
      # Don't want `tab` skip first seleted item.
      row = rowForSelectedItem
    else
      row = @items.findRowForNormalItem(rowForSelectedItem, direction)

    if row?
      @items.selectItemForRow(row)
      @preview()

  previewNextItem: ->
    @previewItemForDirection('next')

  previewPreviousItem: ->
    @previewItemForDirection('previous')

  getQuery: ->
    @editor.lineTextForBufferRow(0)

  excludeFile: ->
    filePath = @items.getSelectedItem()?.filePath
    if filePath? and (filePath not in @excludedFiles)
      @excludedFiles.push(filePath)
      @moveToDifferentFileItem('next')
      @refresh()

  clearExcludedFiles: ->
    if @excludedFiles.length
      @excludedFiles = []
      @refresh()

  refreshManually: (options) ->
    @emitWillRefreshManually()
    @refresh(options)

  refresh: ({force, selectFirstItem, filePath}={}) ->
    @emitWillRefresh()

    getItems = =>
      if @cachedItems? and not force
        Promise.resolve(@cachedItems)
      else
        Promise.resolve(@provider.getItems(filePath)).then (items) =>
          if @provider.showLineHeader
            injectLineHeader(items, showColumn: @provider.showColumnOnLineHeader)
          items = getItemsWithHeaders(items) unless @provider.boundToSingleFile
          @cachedItems = items if @provider.supportCacheItems
          items

    @lastQuery = @getQuery()
    sensitivity = @provider.getConfig('caseSensitivityForNarrowQuery')
    filterSpec = getFilterSpecForQuery(@lastQuery, {sensitivity})
    if @provider.updateGrammarOnQueryChange
      @grammar.update(filterSpec.include) # No need to highlight excluded items

    getItems().then (items) =>
      if @excludedFiles.length
        items = items.filter (item) => item.filePath not in @excludedFiles
      items = @provider.filterItems(items, filterSpec)
      items = getItemsWithoutUnusedHeader(items) unless @provider.boundToSingleFile

      if (not selectFirstItem) and @items.hasSelectedItem()
        oldSelectedItem = @items.getSelectedItem()
        wasAtSelectedItem = @isAtSelectedItem()
        oldColumn = @getCursorColumn()

      @items.setItems(items)
      @renderItems(items)

      if @items.hasNormalItem()
        if oldSelectedItem? and item = @items.findItem(oldSelectedItem)
          @items.selectItem(item)
          if wasAtSelectedItem
            @moveToSelectedItem(ignoreCursorMove: not @isActive())
            @editor.setCursorBufferPosition([@getCursorRow(), oldColumn])
        else
          @items.selectFirstNormalItem()
      else
        @highlighter.clearLineMarker()

      @emitDidRefresh()
      @emitDidStopRefreshing()

  renderItems: (items) ->
    texts = items.map (item) => @provider.viewForItem(item)
    @withIgnoreChange =>
      if @editor.getLastBufferRow() is 0
        # Need to recover query prompt
        @insertQuery()
        @moveToPrompt()
        @controlBar.show()
      itemArea = new Range(@itemAreaStart, @editor.getEofBufferPosition())
      range = @editor.setTextInBufferRange(itemArea, texts.join("\n"), undo: 'skip')
      @setModifiedState(false)
      @editorLastRow = range.end.row

  debouncedPreview: ->
    @_debouncedPreview ?= _.debounce((=> @preview()), 100)
    @_debouncedPreview()

  observeChange: ->
    @editor.buffer.onDidChange ({newRange, oldRange}) =>
      return if @ignoreChange

      promptRange = @getPromptRange()
      onPrompt = (range) -> range.intersectsWith(promptRange)
      isQueryModified = (newRange, oldRange) ->
        (not newRange.isEmpty() and onPrompt(newRange)) or (not oldRange.isEmpty() and onPrompt(oldRange))

      if isQueryModified(newRange, oldRange)
        # is Query changed
        if @editor.hasMultipleCursors()
          # Destroy cursors on prompt to protect query from mutation on 'find-and-replace:select-all'( cmd-alt-g ).
          for selection in @editor.getSelections() when onPrompt(selection.getBufferRange())
            selection.destroy()
          @withIgnoreChange => @insertQuery(@lastQuery) # Recover query
        else
          @refresh(selectFirstItem: true).then =>
            if @autoPreviewOnQueryChange and @isActive()
              if @provider.boundToSingleFile
                @preview()
              else
                @debouncedPreview()
      else
        @setModifiedState(true)

  observeCursorMove: ->
    @editor.onDidChangeCursorPosition (event) =>
      return if @ignoreCursorMove

      {oldBufferPosition, newBufferPosition, textChanged, cursor} = event
      return if textChanged or
        (not cursor.selection.isEmpty()) or
        (oldBufferPosition.row is newBufferPosition.row)

      newRow = newBufferPosition.row
      oldRow = oldBufferPosition.row

      if isHeaderRow = not @isPromptRow(newRow) and not @items.isNormalItemRow(newRow)
        direction = if newRow > oldRow then 'next' else 'previous'
        newRow = @items.findRowForNormalOrPromptItem(newRow, direction)

      if @isPromptRow(newRow)
        @withIgnoreCursorMove =>
          @editor.setCursorBufferPosition([newRow, newBufferPosition.column])
          @emitDidMoveToPrompt()
      else
        @items.selectItemForRow(newRow)
        @moveToSelectedItem() if isHeaderRow
        @emitDidMoveToItemArea() if @isPromptRow(oldRow)
        @preview() if @autoPreview

  # Return success or fail
  syncToEditor: (editor) ->
    return false if @inPreview

    point = editor.getCursorBufferPosition()
    if @provider.boundToSingleFile
      item = @items.findClosestItemForBufferPosition(point)
    else
      item = @items.findClosestItemForBufferPosition(point, filePath: editor.getPath())

    if item?
      @items.selectItem(item)
      wasAtPrompt = @isAtPrompt()
      @moveToSelectedItem(scrollToColumnZero: true)
      @emitDidMoveToItemArea() if wasAtPrompt
      true
    else
      false

  moveToSelectedItem: ({scrollToColumnZero, ignoreCursorMove}={}) ->
    return if (row = @items.getRowForSelectedItem()) is -1

    point = scrollPoint = [row, @getCursorColumn()]
    scrollPoint = [row, 0] if scrollToColumnZero

    moveAndScroll = =>
      # Manually set cursor to center to avoid scrollTop drastically changes
      # when refresh and auto-sync.
      @editor.setCursorBufferPosition(point, autoscroll: false)
      @editor.scrollToBufferPosition(scrollPoint, center: true)

    if ignoreCursorMove ? true
      @withIgnoreCursorMove(moveAndScroll)
    else
      moveAndScroll()

  preview: ->
    return unless item = @items.getSelectedItem()

    @inPreview = true
    @provider.openFileForItem(item).then (editor) =>
      editor.scrollToBufferPosition(item.point, center: true)
      @inPreview = false
      @emitDidPreview({editor, item})

  confirm: ({keepOpen, flash}={}) ->
    return unless item = @items.getSelectedItem()
    needDestroy = not keepOpen and not @protected and @provider.getConfig('closeOnConfirm')

    @provider.confirmed(item).then (editor) =>
      if needDestroy
        @editor.destroy()
      else
        @highlighter.flashItem(editor, item) if flash
        @emitDidConfirm({editor, item})

  # Cursor move and position status
  # ------------------------------
  isAtSelectedItem: ->
    @getCursorRow() is @items.getRowForSelectedItem()

  moveToDifferentFileItem: (direction) ->
    unless @isAtSelectedItem()
      @moveToSelectedItem(ignoreCursorMove: false)
      return

    # Fallback to selected item in case there is only single filePath in all items
    # But want to move to item from query-prompt.
    if item = @items.findDifferentFileItem(direction) ? @items.getSelectedItem()
      @items.selectItem(item)
      @moveToSelectedItem(ignoreCursorMove: false)

  moveToNextFileItem: ->
    @moveToDifferentFileItem('next')

  moveToPreviousFileItem: ->
    @moveToDifferentFileItem('previous')

  moveToPromptOrSelectedItem: ->
    if @isAtSelectedItem()
      @moveToPrompt()
    else
      @moveToBeginningOfSelectedItem()

  moveToBeginningOfSelectedItem: ->
    if @items.hasSelectedItem()
      @editor.setCursorBufferPosition(@items.getFirstPositionForSelectedItem())

  moveToPrompt: ->
    @withIgnoreCursorMove =>
      @editor.setCursorBufferPosition(@getPromptRange().end)
      @setReadOnly(false)
      @emitDidMoveToPrompt()

  getCursorRow: ->
    @editor.getCursorBufferPosition().row

  getCursorColumn: ->
    @editor.getCursorBufferPosition().column
  # -------------------------

  isPromptRow: (row) ->
    row is 0

  isAtPrompt: ->
    @isPromptRow(@getCursorRow())

  getNormalItemsForEditor: (editor) ->
    if @provider.boundToSingleFile
      @items.getNormalItems()
    else
      @items.getNormalItems(editor.getPath())

  updateControlBar: (states) ->
    @controlBar.updateStateElements(states)

  getPromptRange: ->
    @editor.bufferRangeForBufferRow(0)

  # Return range
  insertQuery: (text='') ->
    @editor.setTextInBufferRange([[0, 0], @itemAreaStart], text + "\n")

  startSyncToEditor: (editor) ->
    @syncSubcriptions?.dispose()
    @syncSubcriptions = new CompositeDisposable

    oldFilePath = @provider.editor.getPath()
    newFilePath = editor.getPath()

    @provider.bindEditor(editor)
    @syncToEditor(editor)

    ignoreColumnChange = not @provider.itemHaveRange
    @syncSubcriptions.add editor.onDidChangeCursorPosition (event) =>
      return if event.textChanged
      return if ignoreColumnChange and (event.oldBufferPosition.row is event.newBufferPosition.row)
      @syncToEditor(editor) if isActiveEditor(editor)

    @syncSubcriptions.add @onDidRefresh =>
      @syncToEditor(editor) if isActiveEditor(editor)

    # Suppress refresh while ui is active.
    # Important to update-real-file don't cause auto-refresh.

    if @provider.boundToSingleFile
      # Refresh only when newFilePath is undefined or different from oldFilePath
      unless isDefinedAndEqual(oldFilePath, newFilePath)
        @refresh(force: true)
      @syncSubcriptions.add editor.onDidStopChanging =>
        @refresh(force: true) unless @isActive()
    else
      @syncSubcriptions.add editor.onDidSave (event) =>
        @refresh(force: true, filePath: event.path) unless @isActive()

  # vim-mode-plus integration
  # -------------------------
  vmpActivateNormalMode: ->
    atom.commands.dispatch(@editorElement, 'vim-mode-plus:activate-normal-mode')

  vmpActivateInsertMode: ->
    atom.commands.dispatch(@editorElement, 'vim-mode-plus:activate-insert-mode')

  vmpIsInsertMode: ->
    @vmpIsEnabled() and @editorElement.classList.contains('insert-mode')

  vmpIsNormalMode: ->
    @vmpIsEnabled() and @editorElement.classList.contains('normal-mode')

  vmpIsEnabled: ->
    @editorElement.classList.contains('vim-mode-plus')

  # Direct-edit related
  # -------------------------
  updateRealFile: ->
    return unless @provider.supportDirectEdit
    return unless @isModified()

    if settings.get('confirmOnUpdateRealFile')
      unless atom.confirm(message: 'Update real file?', buttons: ['Update', 'Cancel']) is 0
        return

    return if @editorLastRow isnt @editor.getLastBufferRow()

    # Ensure all item have valid line header
    if @provider.showLineHeader
      itemHaveOriginalLineHeader = (item) =>
        @editor.lineTextForBufferRow(@items.getRowForItem(item)).startsWith(item._lineHeader)
      unless @items.getNormalItems().every(itemHaveOriginalLineHeader)
        return

    changes = []
    lines = @editor.buffer.getLines()
    for line, row in lines when isNormalItem(item = @items.getItemForRow(row))
      if item._lineHeader?
        line = line[item._lineHeader.length...] # Strip lineHeader
      if line isnt item.text
        changes.push({newText: line, item})

    return unless changes.length

    unless @provider.boundToSingleFile
      {success, message} = ensureNoModifiedFileForChanges(changes)
      unless success
        atom.notifications.addWarning(message, dismissable: true)
        return

    {success, message} = ensureNoConflictForChanges(changes)
    unless success
      atom.notifications.addWarning(message, dismissable: true)
      return

    @provider.updateRealFile(changes)
    @setModifiedState(false)
