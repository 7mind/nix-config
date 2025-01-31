[
  {
    command = "outdent";
    key = "shift+tab";
    when = "editorTextFocus && !editorReadonly && !editorTabMovesFocus";
  }
  {
    command = "editor.action.cancelSelectionAnchor";
    key = "escape";
    when = "editorTextFocus && selectionAnchorSet";
  }

  {
    command = "editor.action.triggerParameterHints";
    key = "ctrl+shift+space";
    when = "editorHasSignatureHelpProvider && editorTextFocus";
  }
  {
    command = "editor.action.wordHighlight.next";
    key = "f7";
    when = "editorTextFocus && hasWordHighlights";
  }
  {
    command = "editor.action.wordHighlight.prev";
    key = "shift+f7";
    when = "editorTextFocus && hasWordHighlights";
  }
  {
    command = "workbench.action.editor.nextChange";
    key = "alt+f5";
    when = "editorTextFocus && !textCompareEditorActive";
  }

  {
    command = "editor.action.goToImplementation";
    key = "ctrl+f12";
    when = "editorHasImplementationProvider && editorTextFocus";
  }
  {
    command = "editor.action.goToReferences";
    key = "shift+f12";
    when =
      "editorHasReferenceProvider && editorTextFocus && !inReferenceSearchEditor && !isInEmbeddedEditor";
  }

  {
    command = "workbench.action.interactivePlayground.arrowDown";
    key = "down";
    when = "interactivePlaygroundFocus && !editorTextFocus";
  }
  {
    command = "workbench.action.interactivePlayground.arrowUp";
    key = "up";
    when = "interactivePlaygroundFocus && !editorTextFocus";
  }
  {
    command = "workbench.action.interactivePlayground.pageDown";
    key = "pagedown";
    when = "interactivePlaygroundFocus && !editorTextFocus";
  }
  {
    command = "workbench.action.interactivePlayground.pageUp";
    key = "pageup";
    when = "interactivePlaygroundFocus && !editorTextFocus";
  }

  {
    command = "closeReferenceSearch";
    key = "escape";
    when =
      "editorTextFocus && referenceSearchVisible && !config.editor.stablePeek || referenceSearchVisible && !config.editor.stablePeek && !inputFocus";
  }

  # {
  #   command = "tab";
  #   key = "tab";
  #   when = "editorTextFocus && !editorReadonly && !editorTabMovesFocus";
  # }







  # {
  #   command = "editor.action.selectFromAnchorToCursor";
  #   key = "ctrl+k ctrl+k";
  #   when = "editorTextFocus && selectionAnchorSet";
  # }
  # {
  #   command = "editor.action.setSelectionAnchor";
  #   key = "ctrl+k ctrl+b";
  #   when = "editorTextFocus";
  # }

  # {
  #   command = "editor.action.showHover";
  #   key = "ctrl+k ctrl+i";
  #   when = "editorTextFocus";
  # }

  # {
  #   command = "editor.action.smartSelect.expand";
  #   key = "shift+alt+right";
  #   when = "editorTextFocus";
  # }
  # {
  #   command = "editor.action.smartSelect.shrink";
  #   key = "shift+alt+left";
  #   when = "editorTextFocus";
  # }

  # {
  #   command = "workbench.action.editor.previousChange";
  #   key = "shift+alt+f5";
  #   when = "editorTextFocus && !textCompareEditorActive";
  # }
  # {
  #   command = "editor.detectLanguage";
  #   key = "shift+alt+d";
  #   when = "editorTextFocus && !notebookEditable";
  # }

]
