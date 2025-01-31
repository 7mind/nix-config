[
  {
    command = "openReferenceToSide";
    key = "ctrl+enter";
    when =
      "listFocus && referenceSearchVisible && !inputFocus && !treeElementCanCollapse && !treeElementCanExpand && !treestickyScrollFocused";
  }
  {
    command = "list.clear";
    key = "escape";
    when =
      "listFocus && listHasSelectionOrFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.closeFind";
    key = "escape";
    when = "listFocus && treeFindOpen";
  }
  {
    command = "list.collapse";
    key = "left";
    when =
      "listFocus && treeElementCanCollapse && !inputFocus && !treestickyScrollFocused || listFocus && treeElementHasParent && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.collapseAll";
    key = "ctrl+left";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.expand";
    key = "right";
    when =
      "listFocus && treeElementCanExpand && !inputFocus && !treestickyScrollFocused || listFocus && treeElementHasChild && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.expandSelectionDown";
    key = "shift+down";
    when =
      "listFocus && listSupportsMultiselect && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.expandSelectionUp";
    key = "shift+up";
    when =
      "listFocus && listSupportsMultiselect && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.find";
    key = "f3";
    when = "listFocus && listSupportsFind";
  }
  {
    command = "list.find";
    key = "ctrl+alt+f";
    when = "listFocus && listSupportsFind";
  }
  {
    command = "list.focusAnyDown";
    key = "alt+down";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.focusAnyFirst";
    key = "alt+home";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.focusAnyLast";
    key = "alt+end";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.focusAnyUp";
    key = "alt+up";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.focusDown";
    key = "down";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.focusFirst";
    key = "home";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.focusLast";
    key = "end";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.focusPageDown";
    key = "pagedown";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.focusPageUp";
    key = "pageup";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.focusUp";
    key = "up";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.scrollDown";
    key = "ctrl+down";
    when =
      "listFocus && !inputFocus && !treestickyScrollFocused && listScrollAtBoundary != 'both' && listScrollAtBoundary != 'bottom'";
  }
  {
    command = "list.scrollUp";
    key = "ctrl+up";
    when =
      "listFocus && !inputFocus && !treestickyScrollFocused && listScrollAtBoundary != 'both' && listScrollAtBoundary != 'top'";
  }
  {
    command = "list.select";
    key = "enter";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.selectAll";
    key = "ctrl+a";
    when =
      "listFocus && listSupportsMultiselect && !inputFocus && !treestickyScrollFocused";
  }

  # {
  #   command = "list.showHover";
  #   key = "ctrl+k ctrl+i";
  #   when = "listFocus && !inputFocus && !treestickyScrollFocused";
  # }

  {
    command = "list.toggleExpand";
    key = "space";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "list.toggleSelection";
    key = "ctrl+shift+enter";
    when = "listFocus && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "refactorPreview.toggleCheckedState";
    key = "space";
    when =
      "listFocus && refactorPreview.enabled && !inputFocus && !treestickyScrollFocused";
  }
  {
    command = "revealReference";
    key = "enter";
    when =
      "listFocus && referenceSearchVisible && !inputFocus && !treeElementCanCollapse && !treeElementCanExpand && !treestickyScrollFocused";
  }
  {
    command = "search.action.cancel";
    key = "escape";
    when =
      "listFocus && searchViewletVisible && !inputFocus && !treestickyScrollFocused && searchState != '0'";
  }
  {
    command = "widgetNavigation.focusNext";
    key = "ctrl+down";
    when =
      "inputFocus && navigableContainerFocused || navigableContainerFocused && treestickyScrollFocused || navigableContainerFocused && !listFocus || navigableContainerFocused && listScrollAtBoundary == 'both' || navigableContainerFocused && listScrollAtBoundary == 'bottom'";
  }
  {
    command = "widgetNavigation.focusPrevious";
    key = "ctrl+up";
    when =
      "inputFocus && navigableContainerFocused || navigableContainerFocused && treestickyScrollFocused || navigableContainerFocused && !listFocus || navigableContainerFocused && listScrollAtBoundary == 'both' || navigableContainerFocused && listScrollAtBoundary == 'top'";
  }
]
