[
  {
    bindings = {
      # alt-enter = [ "picker::ConfirmInput" { secondary = false; } ];
      # ctrl-alt-enter = [ "picker::ConfirmInput" { secondary = true; } ];
      # alt-shift-enter = "menu::Restart";
      # "ctrl-+" = "zed::IncreaseBufferFontSize";

      "ctrl-," = "zed::OpenSettings";

      ctrl-- = "zed::DecreaseBufferFontSize";
      ctrl-0 = "zed::ResetBufferFontSize";
      "ctrl-=" = "zed::IncreaseBufferFontSize";
      ctrl-q = "zed::Quit";

      # ctrl-alt-z = "zeta::RateCompletions";
      ctrl-o = "workspace::Open";
      ctrl-shift-w = "workspace::CloseWindow";


      ctrl-c = "menu::Cancel";
      ctrl-enter = "menu::SecondaryConfirm";
      ctrl-escape = "menu::Cancel";
      ctrl-n = "menu::SelectNext";
      ctrl-p = "menu::SelectPrev";
      end = "menu::SelectLast";
      enter = "menu::Confirm";
      escape = "menu::Cancel";
      home = "menu::SelectFirst";
      pagedown = "menu::SelectLast";
      pageup = "menu::SelectFirst";
      shift-pagedown = "menu::SelectLast";
      shift-pageup = "menu::SelectFirst";
      shift-tab = "menu::SelectPrev";
      tab = "menu::SelectNext";

      # ctrl-shift-i = "inline_completion::ToggleMenu";
      # f11 = "zed::ToggleFullScreen";
      open = "workspace::Open";
      # shift-escape = "workspace::ToggleZoom";
    };
  }
  {
    bindings = {
      down = "menu::SelectNext";
      up = "menu::SelectPrev";
    };
    context = "Picker || menu";
  }
  {
    bindings = {
      left = "menu::SelectPrev";
      right = "menu::SelectNext";
    };
    context = "Prompt";
  }
  {
    bindings = {
      # "alt-g b" = "editor::ToggleGitBlame";
      alt-pagedown = "editor::PageDown";
      alt-pageup = "editor::PageUp";
      backspace = "editor::Backspace";
      copy = "editor::Copy";
      # "ctrl-\"" = "editor::ExpandAllHunkDiffs";
      # ctrl-' = "editor::ToggleHunkDiff";
      # "ctrl-;" = "editor::ToggleLineNumbers";
      "ctrl-k ctrl-a" = "editor::SelectAll";
      ctrl-alt-space = "editor::ShowCharacterPalette";
      ctrl-backspace = "editor::DeleteToPreviousWordStart";
      # ctrl-delete = "editor::DeleteToNextWordEnd";

      ctrl-c = "editor::Copy";

      ctrl-down = "editor::LineDown";
      ctrl-end = "editor::MoveToEnd";

      ctrl-home = "editor::MoveToBeginning";
      "ctrl-i ctrl-i" = "editor::ShowSignatureHelp";
      ctrl-insert = "editor::Copy";
      # ctrl-k = "editor::CutToEndOfLine";

      # "ctrl-k ctrl-q" = "editor::Rewrap";
      # "ctrl-k ctrl-r" = "editor::RevertSelectedHunks";

      # "ctrl-k q" = "editor::Rewrap";
      # ctrl-l = "editor::SelectLine";
      ctrl-left = "editor::MoveToPreviousWordStart";
      ctrl-right = "editor::MoveToNextWordEnd";
      alt-left = "editor::MoveToPreviousWordStart";
      alt-right = "editor::MoveToNextWordEnd";

      ctrl-shift-left = "editor::SelectToPreviousWordStart";
      ctrl-shift-right = "editor::SelectToNextWordEnd";
      alt-shift-left = "editor::SelectToPreviousWordStart";
      alt-shift-right = "editor::SelectToNextWordEnd";

      ctrl-shift-end = "editor::SelectToEnd";
      ctrl-shift-home = "editor::SelectToBeginning";

      ctrl-shift-i = "editor::Format";

      ctrl-shift-z = "editor::Redo";
      # ctrl-up = "editor::LineUp";

      ctrl-v = "editor::Paste";
      ctrl-x = "editor::Cut";
      ctrl-y = "editor::Redo";
      ctrl-z = "editor::Undo";

      cut = "editor::Cut";
      delete = "editor::Delete";
      down = "editor::MoveDown";
      end = "editor::MoveToEndOfLine";
      escape = "editor::Cancel";
      home = "editor::MoveToBeginningOfLine";
      left = "editor::MoveLeft";
      menu = "editor::OpenContextMenu";
      pagedown = "editor::MovePageDown";
      pageup = "editor::MovePageUp";
      paste = "editor::Paste";
      redo = "editor::Redo";
      right = "editor::MoveRight";

      shift-backspace = "editor::Backspace";
      shift-delete = "editor::Cut";

      shift-down = "editor::SelectDown";
      shift-end =
        [ "editor::SelectToEndOfLine" { stop_at_soft_wraps = true; } ];
      shift-f10 = "editor::OpenContextMenu";

      shift-home =
        [ "editor::SelectToBeginningOfLine" { stop_at_soft_wraps = true; } ];

      shift-insert = "editor::Paste";
      shift-left = "editor::SelectLeft";
      shift-pagedown = "editor::SelectPageDown";
      shift-pageup = "editor::SelectPageUp";
      shift-right = "editor::SelectRight";
      shift-tab = "editor::TabPrev";
      shift-up = "editor::SelectUp";

      # tab = "editor::Tab";
      undo = "editor::Undo";
      up = "editor::MoveUp";
    };
    context = "Editor";
  }

  {
    bindings = {
      # "ctrl+k ctrl+d" = "editor::GoToTypeDefinitionSplit";
      alt-shift-down = "editor::MoveLineDown";
      # alt-f12 = "editor::GoToDefinitionSplit";

      alt-shift-f12 = "editor::FindAllReferences";
      # alt-shift-left = "editor::SelectSmallerSyntaxNode";
      # alt-shift-right = "editor::SelectLargerSyntaxNode";
      alt-shift-up = "editor::MoveLineUp";

      "ctrl-." = "editor::ToggleCodeActions";

      "ctrl-/" = [ "editor::ToggleComments" { advance_downwards = false; } ];

      shift-tab = "editor::Outdent";
      tab = "editor::Indent";

      "ctrl-k ctrl-v" = "pane::SplitRight";

      # ctrl-alt-shift-c = "editor::DisplayCursorNames";
      super-d = "editor::DuplicateLineDown";
      # ctrl-alt-shift-up = "editor::DuplicateLineUp";

      ctrl-d = [ "editor::SelectNext" { replace_newest = false; } ];
      ctrl-f12 = "editor::GoToTypeDefinition";
      ctrl-f2 = "editor::SelectAllMatches";

      # "ctrl-k ctrl-0" = "editor::FoldAll";
      # "ctrl-k ctrl-1" = [ "editor::FoldAtLevel" { level = 1; } ];
      # "ctrl-k ctrl-2" = [ "editor::FoldAtLevel" { level = 2; } ];
      # "ctrl-k ctrl-3" = [ "editor::FoldAtLevel" { level = 3; } ];
      # "ctrl-k ctrl-4" = [ "editor::FoldAtLevel" { level = 4; } ];
      # "ctrl-k ctrl-5" = [ "editor::FoldAtLevel" { level = 5; } ];
      # "ctrl-k ctrl-6" = [ "editor::FoldAtLevel" { level = 6; } ];
      # "ctrl-k ctrl-7" = [ "editor::FoldAtLevel" { level = 7; } ];
      # "ctrl-k ctrl-8" = [ "editor::FoldAtLevel" { level = 8; } ];
      # "ctrl-k ctrl-9" = [ "editor::FoldAtLevel" { level = 9; } ];
      # "ctrl-k ctrl-[" = "editor::FoldRecursive";
      # "ctrl-k ctrl-]" = "editor::UnfoldRecursive";
      # "ctrl-k ctrl-d" = [ "editor::SelectNext" { replace_newest = true; } ];
      # "ctrl-k ctrl-i" = "editor::Hover";
      # "ctrl-k ctrl-j" = "editor::UnfoldAll";
      # "ctrl-k ctrl-l" = "editor::ToggleFold";

      "ctrl-k ctrl-shift-d" =
        [ "editor::SelectPrevious" { replace_newest = true; } ];

      "ctrl-k p" = "editor::CopyPath";
      "ctrl-k ctrl-f" = "editor::RevealInFileManager";
      # "ctrl-k v" = "markdown::OpenPreviewToTheSide";

      "ctrl-n ctrl+b" = "editor::MoveToEnclosingBracket";
      # "ctrl-shift-[" = "editor::Fold";
      # "ctrl-shift-\\" = "editor::MoveToEnclosingBracket";
      # "ctrl-shift-]" = "editor::UnfoldLines";

      ctrl-shift-down = [ "editor::SelectNext" { replace_newest = false; } ];
      # ctrl-shift-f10 = "editor::GoToDefinitionSplit";
      ctrl-backspace = "editor::DeleteLine";

      ctrl-shift-l = "editor::SelectAllMatches";
      ctrl-shift-u = "editor::RedoSelection";

      ctrl-shift-up = [ "editor::SelectPrevious" { replace_newest = false; } ];

      # ctrl-shift-v = "markdown::OpenPreview";

      ctrl-space = "editor::ShowCompletions";
      ctrl-u = "editor::UndoSelection";
      # f12 = "editor::GoToDefinition";
      "ctrl-t ctrl-r" = "editor::Rename";
      # f8 = "editor::GoToDiagnostic";
      shift-alt-down = "editor::AddSelectionBelow";
      # shift-alt-up = "editor::AddSelectionAbove";
      # shift-f12 = "editor::GoToImplementation";
      # shift-f8 = "editor::GoToPrevDiagnostic";
    };
    context = "Editor";
  }

  # {
  #   bindings = {
  #     ctrl-g = "go_to_line::Toggle";
  #     ctrl-shift-o = "outline::Toggle";
  #   };
  #   context = "Editor && mode == full";
  # }

  {
    bindings = {
      # "ctrl-<" = "assistant::InsertIntoEditor";
      # "ctrl->" = "assistant::QuoteSelection";
      ctrl-alt-e = "editor::SelectEnclosingSymbol";
      ctrl-enter = "editor::NewlineAbove";
      ctrl-f = "buffer_search::Deploy";
      ctrl-h = [ "buffer_search::Deploy" { replace_enabled = true; } ];
      "ctrl-k ctrl-z" = "editor::ToggleSoftWrap";
      "ctrl-k z" = "editor::ToggleSoftWrap";
      ctrl-shift-enter = "editor::NewlineBelow";
      enter = "editor::Newline";
      find = "buffer_search::Deploy";
      shift-enter = "editor::Newline";
    };
    context = "Editor && mode == full";
  }
  {
    bindings = {
      "alt-[" = "editor::PreviousInlineCompletion";
      "alt-]" = "editor::NextInlineCompletion";
      alt-right = "editor::AcceptPartialInlineCompletion";
    };
    context = "Editor && mode == full && inline_completion";
  }
  {
    bindings = { "alt-\\" = "editor::ShowInlineCompletion"; };
    context = "Editor && !inline_completion";
  }
  {
    bindings = {
      ctrl-enter = "editor::Newline";
      ctrl-shift-enter = "editor::NewlineBelow";
      shift-enter = "editor::Newline";
    };
    context = "Editor && mode == auto_height";
  }
  {
    bindings = {
      copy = "markdown::Copy";
      ctrl-c = "markdown::Copy";
    };
    context = "Markdown";
  }
  {
    bindings = {
      "ctrl-alt-/" = "assistant::ToggleModelSelector";
      ctrl-g = "search::SelectNextMatch";
      "ctrl-k c" = "assistant::CopyCode";
      "ctrl-k h" = "assistant::DeployHistory";
      "ctrl-k l" = "assistant::DeployPromptLibrary";
      ctrl-n = "assistant::NewContext";
      ctrl-shift-e = "project_panel::ToggleFocus";
      ctrl-shift-g = "search::SelectPrevMatch";
      new = "assistant::NewContext";
    };
    context = "AssistantPanel";
  }
  {
    bindings = {
      ctrl-n = "prompt_library::NewPrompt";
      ctrl-shift-s = "prompt_library::ToggleDefaultPrompt";
      new = "prompt_library::NewPrompt";
    };
    context = "PromptLibrary";
  }
  {
    bindings = {
      alt-enter = "search::SelectAllMatches";
      ctrl-f = "search::FocusSearch";
      ctrl-h = "search::ToggleReplace";
      ctrl-l = "search::ToggleSelection";
      enter = "search::SelectNextMatch";
      escape = "buffer_search::Dismiss";
      find = "search::FocusSearch";
      shift-enter = "search::SelectPrevMatch";
      tab = "buffer_search::FocusEditor";
    };
    context = "BufferSearchBar";
  }
  {
    bindings = {
      ctrl-enter = "search::ReplaceAll";
      enter = "search::ReplaceNext";
    };
    context = "BufferSearchBar && in_replace > Editor";
  }
  {
    bindings = {
      down = "search::NextHistoryQuery";
      up = "search::PreviousHistoryQuery";
    };
    context = "BufferSearchBar && !in_replace > Editor";
  }
  {
    bindings = {
      alt-ctrl-g = "search::ToggleRegex";
      alt-ctrl-x = "search::ToggleRegex";
      ctrl-shift-f = "search::FocusSearch";
      ctrl-shift-h = "search::ToggleReplace";
      escape = "project_search::ToggleFocus";
      shift-find = "search::FocusSearch";
    };
    context = "ProjectSearchBar";
  }
  {
    bindings = {
      down = "search::NextHistoryQuery";
      up = "search::PreviousHistoryQuery";
    };
    context = "ProjectSearchBar > Editor";
  }
  {
    bindings = {
      ctrl-alt-enter = "search::ReplaceAll";
      enter = "search::ReplaceNext";
    };
    context = "ProjectSearchBar && in_replace > Editor";
  }
  {
    bindings = {
      alt-ctrl-g = "search::ToggleRegex";
      alt-ctrl-x = "search::ToggleRegex";
      ctrl-shift-h = "search::ToggleReplace";
      escape = "project_search::ToggleFocus";
    };
    context = "ProjectSearchView";
  }
  {
    bindings = {
      alt-0 = "pane::ActivateLastItem";
      alt-1 = [ "pane::ActivateItem" 0 ];
      alt-2 = [ "pane::ActivateItem" 1 ];
      alt-3 = [ "pane::ActivateItem" 2 ];
      alt-4 = [ "pane::ActivateItem" 3 ];
      alt-5 = [ "pane::ActivateItem" 4 ];
      alt-6 = [ "pane::ActivateItem" 5 ];
      alt-7 = [ "pane::ActivateItem" 6 ];
      alt-8 = [ "pane::ActivateItem" 7 ];
      alt-9 = [ "pane::ActivateItem" 8 ];
      alt-c = "search::ToggleCaseSensitive";
      alt-ctrl-f = "project_search::ToggleFilters";
      alt-ctrl-shift-w = "workspace::CloseInactiveTabsAndPanes";
      alt-ctrl-t = [ "pane::CloseInactiveItems" { close_pinned = false; } ];
      alt-enter = "search::SelectAllMatches";
      alt-find = "project_search::ToggleFilters";
      alt-r = "search::ToggleRegex";
      alt-w = "search::ToggleWholeWord";
      back = "pane::GoBack";
      ctrl-alt-- = "pane::GoBack";
      ctrl-alt-_ = "pane::GoForward";
      ctrl-alt-g = "search::SelectNextMatch";
      ctrl-alt-shift-g = "search::SelectPrevMatch";
      ctrl-alt-shift-h = "search::ToggleReplace";
      ctrl-alt-shift-l = "search::ToggleSelection";
      ctrl-alt-shift-r = "search::ToggleRegex";
      ctrl-alt-shift-x = "search::ToggleRegex";
      ctrl-f4 = "pane::CloseActiveItem";
      "ctrl-k e" = [ "pane::CloseItemsToTheLeft" { close_pinned = false; } ];
      "ctrl-k shift-enter" = "pane::TogglePinTab";
      "ctrl-k t" = [ "pane::CloseItemsToTheRight" { close_pinned = false; } ];
      "ctrl-k u" = [ "pane::CloseCleanItems" { close_pinned = false; } ];
      "ctrl-k w" = [ "pane::CloseAllItems" { close_pinned = false; } ];
      ctrl-pagedown = "pane::ActivateNextItem";
      ctrl-pageup = "pane::ActivatePrevItem";
      ctrl-shift-f = "project_search::ToggleFocus";
      ctrl-shift-pagedown = "pane::SwapItemRight";
      ctrl-shift-pageup = "pane::SwapItemLeft";
      ctrl-w = "pane::CloseActiveItem";
      f3 = "search::SelectNextMatch";
      forward = "pane::GoForward";
      shift-f3 = "search::SelectPrevMatch";
      shift-find = "project_search::ToggleFocus";
    };
    context = "Pane";
  }

  {
    bindings = {
      alt-1 = [ "workspace::ActivatePane" 0 ];
      alt-2 = [ "workspace::ActivatePane" 1 ];
      alt-3 = [ "workspace::ActivatePane" 2 ];
      alt-4 = [ "workspace::ActivatePane" 3 ];
      alt-5 = [ "workspace::ActivatePane" 4 ];
      alt-6 = [ "workspace::ActivatePane" 5 ];
      alt-7 = [ "workspace::ActivatePane" 6 ];
      alt-8 = [ "workspace::ActivatePane" 7 ];
      alt-9 = [ "workspace::ActivatePane" 8 ];
      alt-ctrl-o = "projects::OpenRecent";
      alt-ctrl-shift-b = "branches::OpenRecent";
      alt-ctrl-shift-o = "projects::OpenRemote";
      alt-open = "projects::OpenRecent";
      alt-save = "workspace::SaveAll";
      alt-shift-open = "projects::OpenRemote";
      alt-shift-r = [ "task::Spawn" { reveal_target = "center"; } ];
      alt-shift-t = "task::Spawn";
      alt-t = "task::Rerun";
      "ctrl-?" = "assistant::ToggleFocus";
      "ctrl-`" = "terminal_panel::ToggleFocus";
      ctrl-alt-b = "workspace::ToggleRightDock";
      ctrl-alt-r = "task::Rerun";
      ctrl-alt-s = "workspace::SaveAll";
      ctrl-alt-y = "workspace::CloseAllDocks";
      ctrl-b = "workspace::ToggleLeftDock";
      ctrl-e = "file_finder::Toggle";
      ctrl-j = "workspace::ToggleBottomDock";
      "ctrl-k ctrl-down" = [ "workspace::ActivatePaneInDirection" "Down" ];
      "ctrl-k ctrl-left" = [ "workspace::ActivatePaneInDirection" "Left" ];
      "ctrl-k ctrl-right" = [ "workspace::ActivatePaneInDirection" "Right" ];
      "ctrl-k ctrl-s" = "zed::OpenKeymap";
      "ctrl-k ctrl-t" = "theme_selector::Toggle";
      "ctrl-k ctrl-up" = [ "workspace::ActivatePaneInDirection" "Up" ];
      "ctrl-k m" = "language_selector::Toggle";
      "ctrl-k s" = "workspace::SaveWithoutFormat";
      "ctrl-k shift-down" = [ "workspace::SwapPaneInDirection" "Down" ];
      "ctrl-k shift-left" = [ "workspace::SwapPaneInDirection" "Left" ];
      "ctrl-k shift-right" = [ "workspace::SwapPaneInDirection" "Right" ];
      "ctrl-k shift-up" = [ "workspace::SwapPaneInDirection" "Up" ];
      "ctrl-k ctrl-n" = "workspace::NewFile";
      ctrl-p = "file_finder::Toggle";
      ctrl-s = "workspace::Save";
      ctrl-shift-b = "outline_panel::ToggleFocus";
      ctrl-shift-e = "project_panel::ToggleFocus";
      ctrl-shift-f = "pane::DeploySearch";
      ctrl-shift-h = [ "pane::DeploySearch" { replace_enabled = true; } ];
      ctrl-shift-m = "diagnostics::Deploy";
      ctrl-shift-n = "workspace::NewWindow";
      "ctrl-n ctrl-n" = "command_palette::Toggle";

      ctrl-shift-r = "task::Rerun";
      ctrl-shift-s = "workspace::SaveAs";
      ctrl-shift-t = "pane::ReopenClosedItem";
      ctrl-shift-tab = [ "tab_switcher::Toggle" { select_last = true; } ];
      ctrl-shift-x = "zed::Extensions";
      ctrl-t = "project_symbols::Toggle";
      ctrl-tab = "tab_switcher::Toggle";
      "ctrl-~" = "workspace::NewTerminal";
      escape = "workspace::Unfollow";
      f1 = "command_palette::Toggle";
      new = "workspace::NewFile";
      save = "workspace::Save";
      shift-find = "pane::DeploySearch";
      shift-new = "workspace::NewWindow";
      shift-save = "workspace::SaveAs";
    };
    context = "Workspace";
  }
  {
    bindings = {
      left = [ "app_menu::NavigateApplicationMenuInDirection" "Left" ];
      right = [ "app_menu::NavigateApplicationMenuInDirection" "Right" ];
    };
    context = "ApplicationMenu";
  }
  {
    bindings = {
      ctrl-alt-backspace = "editor::DeleteToPreviousSubwordStart";
      ctrl-alt-d = "editor::DeleteToNextSubwordEnd";
      ctrl-alt-delete = "editor::DeleteToNextSubwordEnd";
      ctrl-alt-f = "editor::MoveToNextSubwordEnd";
      ctrl-alt-h = "editor::DeleteToPreviousSubwordStart";
      ctrl-alt-left = "editor::MoveToPreviousSubwordStart";
      ctrl-alt-right = "editor::MoveToNextSubwordEnd";
      ctrl-alt-shift-b = "editor::SelectToPreviousSubwordStart";
      ctrl-alt-shift-f = "editor::SelectToNextSubwordEnd";
      ctrl-alt-shift-left = "editor::SelectToPreviousSubwordStart";
      ctrl-alt-shift-right = "editor::SelectToNextSubwordEnd";
      ctrl-shift-d = "editor::DuplicateLineDown";
      ctrl-shift-j = "editor::JoinLines";
    };
    context = "Editor";
  }
  {
    bindings = {
      "ctrl-k down" = "pane::SplitDown";
      "ctrl-k left" = "pane::SplitLeft";
      "ctrl-k right" = "pane::SplitRight";
      "ctrl-k up" = "pane::SplitUp";
    };
    context = "Pane";
  }
  {
    bindings = { enter = "editor::ConfirmRename"; };
    context = "Editor && renaming";
  }
  {
    bindings = {
      enter = "editor::ConfirmCompletion";
      tab = "editor::ComposeCompletion";
    };
    context = "Editor && showing_completions";
    use_key_equivalents = true;
  }
  {
    bindings = { tab = "editor::AcceptInlineCompletion"; };
    context = "Editor && inline_completion && !showing_completions";
    use_key_equivalents = true;
  }
  {
    bindings = { enter = "editor::ConfirmCodeAction"; };
    context = "Editor && showing_code_actions";
  }
  {
    bindings = {
      ctrl-n = "editor::ContextMenuNext";
      ctrl-p = "editor::ContextMenuPrev";
      down = "editor::ContextMenuNext";
      pagedown = "editor::ContextMenuLast";
      pageup = "editor::ContextMenuFirst";
      up = "editor::ContextMenuPrev";
    };
    context = "Editor && (showing_code_actions || showing_completions)";
  }
  {
    bindings = {
      "ctrl-:" = "editor::ToggleInlayHints";
      ctrl-alt-i = "zed::DebugElements";
      ctrl-alt-shift-f = "workspace::FollowNextCollaborator";
    };
  }
  {
    bindings = { ctrl-shift-c = "collab_panel::ToggleFocus"; };
    context = "!Terminal";
  }
  {
    bindings = {
      alt-enter = "editor::OpenExcerpts";
      ctrl-enter = "assistant::InlineAssist";
      ctrl-f8 = "editor::GoToHunk";
      "ctrl-k enter" = "editor::OpenExcerptsSplit";
      ctrl-shift-e = "pane::RevealInProjectPanel";
      ctrl-shift-f8 = "editor::GoToPrevHunk";
      shift-enter = "editor::ExpandExcerpts";
    };
    context = "Editor && mode == full";
  }
  {
    bindings = {
      ctrl-alt-a = "editor::ApplyAllDiffHunks";
      ctrl-shift-y = "editor::ApplyDiffHunk";
    };
    context = "ProposedChangesEditor";
  }
  {
    bindings = {
      ctrl-alt-enter = "repl::RunInPlace";
      ctrl-shift-enter = "repl::Run";
    };
    context = "Editor && jupyter && !ContextEditor";
  }
  {
    bindings = {
      alt-enter = "editor::Newline";
      "ctrl-<" = "assistant::InsertIntoEditor";
      "ctrl->" = "assistant::QuoteSelection";
      ctrl-enter = "assistant::Assist";
      ctrl-r = "assistant::CycleMessageRole";
      ctrl-s = "workspace::Save";
      ctrl-shift-enter = "assistant::Edit";
      enter = "assistant::ConfirmCommand";
      save = "workspace::Save";
      shift-enter = "assistant::Split";
    };
    context = "ContextEditor > Editor";
  }
  {
    bindings = {
      "ctrl-alt-/" = "assistant2::ToggleModelSelector";
      ctrl-alt-e = "assistant2::RemoveAllContext";
      ctrl-e = "assistant2::ChatMode";
      ctrl-n = "assistant2::NewThread";
      ctrl-shift-a = "assistant2::ToggleContextPicker";
      ctrl-shift-h = "assistant2::OpenHistory";
      new = "assistant2::NewThread";
    };
    context = "AssistantPanel2";
  }
  {
    bindings = { enter = "assistant2::Chat"; };
    context = "MessageEditor > Editor";
    use_key_equivalents = true;
  }
  {
    bindings = {
      backspace = "assistant2::RemoveFocusedContext";
      down = "assistant2::FocusDown";
      enter = "assistant2::AcceptSuggestedContext";
      left = "assistant2::FocusLeft";
      right = "assistant2::FocusRight";
      up = "assistant2::FocusUp";
    };
    context = "ContextStrip";
    use_key_equivalents = true;
  }
  {
    bindings = { backspace = "assistant2::RemoveSelectedThread"; };
    context = "ThreadHistory";
  }
  {
    bindings = {
      "ctrl-[" = "assistant::CyclePreviousInlineAssist";
      "ctrl-]" = "assistant::CycleNextInlineAssist";
      ctrl-alt-e = "assistant2::RemoveAllContext";
    };
    context = "PromptEditor";
  }
  {
    bindings = { ctrl-enter = "project_search::SearchInNew"; };
    context = "ProjectSearchBar && !in_replace";
  }
  {
    bindings = {
      alt-copy = "outline_panel::CopyPath";
      alt-ctrl-r = "outline_panel::RevealInFileManager";
      alt-ctrl-shift-c = "outline_panel::CopyRelativePath";
      alt-enter = "editor::OpenExcerpts";
      alt-shift-copy = "outline_panel::CopyRelativePath";
      ctrl-alt-c = "outline_panel::CopyPath";
      "ctrl-k enter" = "editor::OpenExcerptsSplit";
      escape = "menu::Cancel";
      left = "outline_panel::CollapseSelectedEntry";
      right = "outline_panel::ExpandSelectedEntry";
      shift-down = "menu::SelectNext";
      shift-up = "menu::SelectPrev";
      space = "outline_panel::Open";
    };
    context = "OutlinePanel && not_editing";
  }
  {
    bindings = {
      alt-copy = "project_panel::CopyPath";
      alt-ctrl-n = "project_panel::NewDirectory";
      alt-ctrl-r = "project_panel::RevealInFileManager";
      alt-ctrl-shift-c = "project_panel::CopyRelativePath";
      alt-new = "project_panel::NewDirectory";
      alt-shift-copy = "project_panel::CopyRelativePath";
      backspace = [ "project_panel::Trash" { skip_prompt = false; } ];
      copy = "project_panel::Copy";
      ctrl-alt-c = "project_panel::CopyPath";
      ctrl-backspace = [ "project_panel::Delete" { skip_prompt = false; } ];
      ctrl-c = "project_panel::Copy";
      ctrl-delete = [ "project_panel::Delete" { skip_prompt = false; } ];
      ctrl-insert = "project_panel::Copy";
      ctrl-n = "project_panel::NewFile";
      ctrl-shift-enter = "project_panel::OpenWithSystem";
      ctrl-shift-f = "project_panel::NewSearchInDirectory";
      ctrl-v = "project_panel::Paste";
      ctrl-x = "project_panel::Cut";
      cut = "project_panel::Cut";
      delete = [ "project_panel::Trash" { skip_prompt = false; } ];
      "ctrl-t ctrl-r" = "project_panel::Rename";
      escape = "menu::Cancel";
      # f2 = "project_panel::Rename";
      left = "project_panel::CollapseSelectedEntry";
      new = "project_panel::NewFile";
      paste = "project_panel::Paste";
      right = "project_panel::ExpandSelectedEntry";
      shift-delete = [ "project_panel::Delete" { skip_prompt = false; } ];
      shift-down = "menu::SelectNext";
      shift-find = "project_panel::NewSearchInDirectory";
      shift-insert = "project_panel::Paste";
      shift-up = "menu::SelectPrev";
    };
    context = "ProjectPanel";
  }
  {
    bindings = { space = "project_panel::Open"; };
    context = "ProjectPanel && not_editing";
  }
  {
    bindings = {
      ctrl-backspace = "collab_panel::Remove";
      space = "menu::Confirm";
    };
    context = "CollabPanel && not_editing";
  }
  {
    bindings = { space = "collab_panel::InsertSpace"; };
    context = "(CollabPanel && editing) > Editor";
  }
  {
    bindings = { tab = "channel_modal::ToggleMode"; };
    context = "ChannelModal";
  }
  {
    bindings = {
      alt-enter = [ "picker::ConfirmInput" { secondary = false; } ];
      tab = "picker::ConfirmCompletion";
    };
    context = "Picker > Editor";
  }
  {
    bindings = { tab = "channel_modal::ToggleMode"; };
    context = "ChannelModal > Picker > Editor";
  }
  {
    bindings = { ctrl = "file_finder::ToggleMenu"; };
    context = "FileFinder";
  }
  {
    bindings = {
      # ctrl-h = "pane::SplitLeft";
      # ctrl-j = "pane::SplitDown";
      # ctrl-k = "pane::SplitUp";
      "ctrl-k ctrl-v" = "pane::SplitRight";
      #ctrl-shift-p = "file_finder::SelectPrev";
    };
    context = "FileFinder && !menu_open";
  }
  {
    bindings = {
      h = "pane::SplitLeft";
      j = "pane::SplitDown";
      k = "pane::SplitUp";
      l = "pane::SplitRight";
    };
    context = "FileFinder && menu_open";
  }
  {
    bindings = {
      ctrl-backspace = "tab_switcher::CloseSelectedItem";
      ctrl-down = "menu::SelectNext";
      ctrl-shift-tab = "menu::SelectPrev";
      ctrl-up = "menu::SelectPrev";
    };
    context = "TabSwitcher";
  }
  {
    bindings = {
      copy = "terminal::Copy";
      ctrl-alt-space = "terminal::ShowCharacterPalette";
      ctrl-c = [ "terminal::SendKeystroke" "ctrl-c" ];
      ctrl-e = [ "terminal::SendKeystroke" "ctrl-e" ];
      ctrl-enter = "assistant::InlineAssist";
      ctrl-insert = "terminal::Copy";
      ctrl-shift-a = "editor::SelectAll";
      ctrl-shift-c = "terminal::Copy";
      ctrl-shift-f = "buffer_search::Deploy";
      ctrl-shift-l = "terminal::Clear";
      ctrl-shift-space = "terminal::ToggleViMode";
      ctrl-shift-v = "terminal::Paste";
      ctrl-shift-w = "pane::CloseActiveItem";
      ctrl-w = [ "terminal::SendKeystroke" "ctrl-w" ];
      down = [ "terminal::SendKeystroke" "down" ];
      enter = [ "terminal::SendKeystroke" "enter" ];
      escape = [ "terminal::SendKeystroke" "escape" ];
      find = "buffer_search::Deploy";
      pagedown = [ "terminal::SendKeystroke" "pagedown" ];
      pageup = [ "terminal::SendKeystroke" "pageup" ];
      paste = "terminal::Paste";
      shift-down = "terminal::ScrollLineDown";
      shift-end = "terminal::ScrollToBottom";
      shift-home = "terminal::ScrollToTop";
      shift-insert = "terminal::Paste";
      shift-pagedown = "terminal::ScrollPageDown";
      shift-pageup = "terminal::ScrollPageUp";
      shift-up = "terminal::ScrollLineUp";
      up = [ "terminal::SendKeystroke" "up" ];
    };
    context = "Terminal";
  }
]
