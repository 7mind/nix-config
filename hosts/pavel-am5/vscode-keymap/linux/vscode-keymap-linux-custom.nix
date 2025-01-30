let
  PageUp = "meta+[ArrowUp]";
  PageDown = "meta+[ArrowDown]";

  FullHome = "meta+[ArrowLeft]";
  Begin2 = "ctrl+[KeyA]";

  FullEnd = "meta+[ArrowRight]";
  End2 = "ctrl+[KeyE]";
in
[
  {
    command = "quickInput.first";
    key = "home";
    when = "inQuickInput && quickInputType == 'quickPick'";
  }
  {
    command = "quickInput.first";
    key = FullHome;
    when = "inQuickInput && quickInputType == 'quickPick'";
  }

  {
    command = "quickInput.last";
    key = "end";
    when = "inQuickInput && quickInputType == 'quickPick'";
  }
  {
    command = "quickInput.last";
    key = FullEnd;
    when = "inQuickInput && quickInputType == 'quickPick'";
  }


  {
    command = "quickInput.pageNext";
    key = "pagedown";
    when = "inQuickInput && quickInputType == 'quickPick'";
  }
  {
    command = "quickInput.pageNext";
    key = PageDown;
    when = "inQuickInput && quickInputType == 'quickPick'";
  }

  {
    command = "quickInput.pagePrevious";
    key = "pageup";
    when = "inQuickInput && quickInputType == 'quickPick'";
  }
  {
    command = "quickInput.pagePrevious";
    key = PageUp;
    when = "inQuickInput && quickInputType == 'quickPick'";
  }

  {
    command = "quickInput.next";
    key = "down";
    when = "inQuickInput && quickInputType == 'quickPick'";
  }
  {
    command = "quickInput.previous";
    key = "up";
    when = "inQuickInput && quickInputType == 'quickPick'";
  }
  {
    command = "quickInput.acceptInBackground";
    key = "right";
    when =
      "cursorAtEndOfQuickInputBox && inQuickInput && quickInputType == 'quickPick' || inQuickInput && !inputFocus && quickInputType == 'quickPick'";
  }

  #
  {
    command = "cursorHome";
    key = "home";
    when = "textInputFocus";
  }
  {
    command = "cursorHome";
    key = Begin2;
    when = "textInputFocus";
  }

  {
    args = { sticky = false; };
    command = "cursorEnd";
    key = "end";
    when = "textInputFocus";
  }
  {
    args = { sticky = false; };
    command = "cursorEnd";
    key = End2;
    when = "textInputFocus";
  }

  #
  {
    command = "cursorPageDown";
    key = "pagedown";
    when = "textInputFocus";
  }
  {
    command = "cursorPageDown";
    key = PageDown;
    when = "textInputFocus";
  }
  {
    command = "cursorPageUp";
    key = "pageup";
    when = "textInputFocus";
  }
  {
    command = "cursorPageUp";
    key = PageUp;
    when = "textInputFocus";
  }

  #
  {
    command = "cursorWordEndRight";
    key = "alt+right";
    when = "textInputFocus";
  }
  {
    command = "cursorWordLeft";
    key = "alt+left";
    when = "textInputFocus";
  }

  {
    command = "cursorWordEndRightSelect";
    key = "shift+alt+right";
    when = "textInputFocus";
  }
  {
    command = "cursorWordLeftSelect";
    key = "shift+alt+left";
    when = "textInputFocus";
  }

  {
    command = "deleteWordLeft";
    key = "alt+backspace";
    when = "textInputFocus && !editorReadonly";
  }

  {
    command = "editor.action.deleteLines";
    key = "ctrl+backspace";
    when = "textInputFocus && !editorReadonly";

  }

  #
  {
    command = "editor.action.quickFix";
    key = "ctrl+.";
    when = "editorHasCodeActionsProvider && textInputFocus && !editorReadonly";
  }
  {
    command = "editor.action.autoFix";
    key = "ctrl+shift+.";
    when =
      "textInputFocus && !editorReadonly && supportedCodeAction =~ /(\\s|^)quickfix\\b/";
  }
  {
    command = "editor.action.refactor";
    key = "ctrl+[KeyT] ctrl+[KeyT]";
    when = "editorHasCodeActionsProvider && textInputFocus && !editorReadonly";
  }

  #
  {
    command = "editor.action.copyLinesDownAction";
    key = "ctrl+[KeyD]";
    when = "editorTextFocus && !editorReadonly";
  }
  {
    command = "editor.action.copyLinesDownAction";
    key = "meta+[KeyD]";
    when = "editorTextFocus && !editorReadonly";
  }

  #
  {
    command = "editor.action.revealDefinition";
    key = "ctrl+[KeyK] ctrl+[KeyD]";
    when = "editorHasDefinitionProvider && editorTextFocus";
  }
  {
    command = "editor.action.revealDefinitionAside";
    key = "ctrl+[KeyK] ctrl+[KeyD]";
    when =
      "editorHasDefinitionProvider && editorTextFocus && !isInEmbeddedEditor";
  }

  # {
  #   command = "editor.action.peekDefinition";
  #   key = "ctrl+shift+f10";
  #   when =
  #     "editorHasDefinitionProvider && editorTextFocus && !inReferenceSearchEditor && !isInEmbeddedEditor";
  # }
  # {
  #   command = "editor.action.peekImplementation";
  #   key = "ctrl+shift+f12";
  #   when =
  #     "editorHasImplementationProvider && editorTextFocus && !inReferenceSearchEditor && !isInEmbeddedEditor";
  # }
]
