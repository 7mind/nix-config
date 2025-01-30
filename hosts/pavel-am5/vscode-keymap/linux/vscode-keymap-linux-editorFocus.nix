[
  {
    command = "actions.find";
    key = "ctrl+f";
    when = "editorFocus || editorIsOpen";
  }
  {
    command = "editor.action.startFindReplaceAction";
    key = "ctrl+r";
    when = "editorFocus || editorIsOpen";
  }

  # {
  #   command = "editor.action.addSelectionToNextFindMatch";
  #   key = "ctrl+d";
  #   when = "editorFocus";
  # }

  {
    command = "editor.action.extensioneditor.findNext";
    key = "enter";
    when =
      "webviewFindWidgetFocused && !editorFocus && activeEditor == 'workbench.editor.extension'";
  }
  {
    command = "editor.action.extensioneditor.findPrevious";
    key = "shift+enter";
    when =
      "webviewFindWidgetFocused && !editorFocus && activeEditor == 'workbench.editor.extension'";
  }

  {
    command = "editor.action.extensioneditor.showfind";
    key = "ctrl+f";
    when = "!editorFocus && activeEditor == 'workbench.editor.extension'";
  }

  {
    command = "editor.action.marker.next";
    key = "alt+f8";
    when = "editorFocus";
  }
  {
    command = "editor.action.marker.nextInFiles";
    key = "f8";
    when = "editorFocus";
  }
  {
    command = "editor.action.marker.prev";
    key = "shift+alt+f8";
    when = "editorFocus";
  }
  {
    command = "editor.action.marker.prevInFiles";
    key = "shift+f8";
    when = "editorFocus";
  }
  
  {
    command = "editor.action.moveSelectionToNextFindMatch";
    key = "ctrl+k ctrl+d";
    when = "editorFocus";
  }
  {
    command = "editor.action.nextMatchFindAction";
    key = "f3";
    when = "editorFocus";
  }
  {
    command = "editor.action.nextMatchFindAction";
    key = "enter";
    when = "editorFocus && findInputFocussed";
  }
  {
    command = "editor.action.nextSelectionMatchFindAction";
    key = "ctrl+f3";
    when = "editorFocus";
  }
  {
    command = "editor.action.previousMatchFindAction";
    key = "shift+f3";
    when = "editorFocus";
  }
  {
    command = "editor.action.previousMatchFindAction";
    key = "shift+enter";
    when = "editorFocus && findInputFocussed";
  }
  {
    command = "editor.action.previousSelectionMatchFindAction";
    key = "ctrl+shift+f3";
    when = "editorFocus";
  }
  {
    command = "editor.action.selectHighlights";
    key = "ctrl+shift+l";
    when = "editorFocus";
  }
  {
    command = "closeFindWidget";
    key = "escape";
    when = "editorFocus && findWidgetVisible && !isComposing";
  }
  {
    command = "editor.action.replaceAll";
    key = "ctrl+alt+enter";
    when = "editorFocus && findWidgetVisible";
  }
  {
    command = "editor.action.replaceOne";
    key = "ctrl+shift+1";
    when = "editorFocus && findWidgetVisible";
  }
  {
    command = "editor.action.replaceOne";
    key = "enter";
    when = "editorFocus && findWidgetVisible && replaceInputFocussed";
  }
  {
    command = "editor.action.selectAllMatches";
    key = "alt+enter";
    when = "editorFocus && findWidgetVisible";
  }
  {
    command = "toggleFindCaseSensitive";
    key = "alt+c";
    when = "editorFocus";
  }
  {
    command = "toggleFindInSelection";
    key = "alt+l";
    when = "editorFocus";
  }
  {
    command = "toggleFindRegex";
    key = "alt+r";
    when = "editorFocus";
  }
  {
    command = "toggleFindWholeWord";
    key = "alt+w";
    when = "editorFocus";
  }
  {
    command = "togglePreserveCase";
    key = "alt+p";
    when = "editorFocus";
  }
  {
    command = "closeMarkersNavigation";
    key = "escape";
    when = "editorFocus && markersNavigationVisible";
  }
  {
    command = "closeParameterHints";
    key = "escape";
    when = "editorFocus && parameterHintsVisible";
  }
  {
    command = "showNextParameterHint";
    key = "down";
    when =
      "editorFocus && parameterHintsMultipleSignatures && parameterHintsVisible";
  }
  {
    command = "showPrevParameterHint";
    key = "up";
    when =
      "editorFocus && parameterHintsMultipleSignatures && parameterHintsVisible";
  }
  {
    command = "acceptRenameInput";
    key = "enter";
    when = "editorFocus && renameInputVisible && !isComposing";
  }
  {
    command = "acceptRenameInputWithPreview";
    key = "ctrl+enter";
    when =
      "config.editor.rename.enablePreview && editorFocus && renameInputVisible && !isComposing";
  }
  {
    command = "cancelRenameInput";
    key = "escape";
    when = "editorFocus && renameInputVisible";
  }
  {
    command = "copyFilePath";
    key = "ctrl+alt+c";
    when = "!editorFocus";
  }
  {
    command = "copyFilePath";
    key = "ctrl+k ctrl+alt+c";
    when = "editorFocus";
  }
  {
    command = "copyRelativeFilePath";
    key = "ctrl+shift+alt+c";
    when = "!editorFocus";
  }
  {
    command = "copyRelativeFilePath";
    key = "ctrl+k ctrl+shift+alt+c";
    when = "editorFocus";
  }
  {
    command = "revealFileInOS";
    key = "ctrl+alt+r";
    when = "!editorFocus";
  }
]
