[
  {
    command = "outdent";
    key = "shift+tab";
    when = "editorTextFocus && !editorReadonly && !editorTabMovesFocus";
  }
  {
    command = "tab";
    key = "tab";
    when = "editorTextFocus && !editorReadonly && !editorTabMovesFocus";
  }
  {
    command = "editor.action.blockComment";
    key = "ctrl+shift+a";
    when = "editorTextFocus && !editorReadonly";
  }
  {
    command = "editor.action.cancelSelectionAnchor";
    key = "escape";
    when = "editorTextFocus && selectionAnchorSet";
  }
  {
    command = "editor.action.commentLine";
    key = "ctrl+/";
    when = "editorTextFocus && !editorReadonly";
  }
  {
    command = "editor.action.formatDocument";
    key = "ctrl+shift+i";
    when =
      "editorHasDocumentFormattingProvider && editorTextFocus && !editorReadonly && !inCompositeEditor";
  }
  {
    command = "editor.action.formatDocument.none";
    key = "ctrl+shift+i";
    when =
      "editorTextFocus && !editorHasDocumentFormattingProvider && !editorReadonly";
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
    command = "editor.action.indentLines";
    key = "ctrl+]";
    when = "editorTextFocus && !editorReadonly";
  }
  {
    command = "editor.action.outdentLines";
    key = "ctrl+[";
    when = "editorTextFocus && !editorReadonly";
  }
  {
    command = "editor.action.insertCursorAbove";
    key = "ctrl+shift+up";
    when = "editorTextFocus";
  }
  {
    command = "editor.action.insertCursorBelow";
    key = "ctrl+shift+down";
    when = "editorTextFocus";
  }
  {
    command = "editor.action.insertLineAfter";
    key = "ctrl+enter";
    when = "editorTextFocus && !editorReadonly";
  }
  {
    command = "editor.action.insertLineBefore";
    key = "ctrl+shift+enter";
    when = "editorTextFocus && !editorReadonly";
  }
  {
    command = "editor.action.moveLinesDownAction";
    key = "alt+down";
    when = "editorTextFocus && !editorReadonly";
  }
  {
    command = "editor.action.moveLinesUpAction";
    key = "alt+up";
    when = "editorTextFocus && !editorReadonly";
  }
  {
    command = "editor.action.peekDefinition";
    key = "ctrl+shift+f10";
    when =
      "editorHasDefinitionProvider && editorTextFocus && !inReferenceSearchEditor && !isInEmbeddedEditor";
  }
  {
    command = "editor.action.peekImplementation";
    key = "ctrl+shift+f12";
    when =
      "editorHasImplementationProvider && editorTextFocus && !inReferenceSearchEditor && !isInEmbeddedEditor";
  }
  {
    command = "editor.action.rename";
    key = "f2";
    when = "editorHasRenameProvider && editorTextFocus && !editorReadonly";
  }
  {
    command = "editor.action.revealDefinition";
    key = "f12";
    when = "editorHasDefinitionProvider && editorTextFocus";
  }
  {
    command = "editor.action.revealDefinitionAside";
    key = "ctrl+k f12";
    when =
      "editorHasDefinitionProvider && editorTextFocus && !isInEmbeddedEditor";
  }
  {
    command = "editor.action.selectFromAnchorToCursor";
    key = "ctrl+k ctrl+k";
    when = "editorTextFocus && selectionAnchorSet";
  }
  {
    command = "editor.action.setSelectionAnchor";
    key = "ctrl+k ctrl+b";
    when = "editorTextFocus";
  }
  {
    command = "editor.action.showHover";
    key = "ctrl+k ctrl+i";
    when = "editorTextFocus";
  }
  {
    command = "editor.action.smartSelect.expand";
    key = "shift+alt+right";
    when = "editorTextFocus";
  }
  {
    command = "editor.action.smartSelect.shrink";
    key = "shift+alt+left";
    when = "editorTextFocus";
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
    command = "workbench.action.editor.previousChange";
    key = "shift+alt+f5";
    when = "editorTextFocus && !textCompareEditorActive";
  }
  {
    command = "editor.detectLanguage";
    key = "shift+alt+d";
    when = "editorTextFocus && !notebookEditable";
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
]
