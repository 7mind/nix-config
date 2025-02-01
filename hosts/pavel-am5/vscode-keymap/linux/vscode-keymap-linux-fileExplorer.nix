[
  {
    command = "filesExplorer.findInFolder";
    key = "alt+[KeyF]";
    when =
      "explorerResourceIsFolder && filesExplorerFocus && foldersViewVisible && !inputFocus";
  }
  {
    command = "filesExplorer.paste";
    key = "ctrl+v";
    when =
      "filesExplorerFocus && foldersViewVisible && !explorerResourceReadonly && !inputFocus";
  }
  {
    command = "deleteFile";
    key = "shift+delete";
    when =
      "filesExplorerFocus && foldersViewVisible && !explorerResourceReadonly && !inputFocus";
  }
  {
    command = "deleteFile";
    key = "delete";
    when =
      "filesExplorerFocus && foldersViewVisible && !explorerResourceMoveableToTrash && !explorerResourceReadonly && !inputFocus";
  }
  {
    command = "explorer.openAndPassFocus";
    key = "enter";
    when =
      "filesExplorerFocus && foldersViewVisible && !explorerResourceIsFolder && !inputFocus";
  }
  {
    command = "filesExplorer.cancelCut";
    key = "escape";
    when =
      "explorerResourceCut && filesExplorerFocus && foldersViewVisible && !inputFocus";
  }
  {
    command = "filesExplorer.copy";
    key = "ctrl+c";
    when =
      "filesExplorerFocus && foldersViewVisible && !explorerResourceIsRoot && !inputFocus";
  }
  {
    command = "filesExplorer.cut";
    key = "ctrl+x";
    when =
      "filesExplorerFocus && foldersViewVisible && !explorerResourceIsRoot && !explorerResourceReadonly && !inputFocus";
  }
  {
    command = "filesExplorer.openFilePreserveFocus";
    key = "space";
    when =
      "filesExplorerFocus && foldersViewVisible && !explorerResourceIsFolder && !inputFocus";
  }
  {
    command = "firstCompressedFolder";
    key = "home";
    when =
      "explorerViewletCompressedFocus && filesExplorerFocus && foldersViewVisible && !explorerViewletCompressedFirstFocus && !inputFocus";
  }
  {
    command = "lastCompressedFolder";
    key = "end";
    when =
      "explorerViewletCompressedFocus && filesExplorerFocus && foldersViewVisible && !explorerViewletCompressedLastFocus && !inputFocus";
  }
  {
    command = "moveFileToTrash";
    key = "delete";
    when =
      "explorerResourceMoveableToTrash && filesExplorerFocus && foldersViewVisible && !explorerResourceReadonly && !inputFocus";
  }
  {
    command = "nextCompressedFolder";
    key = "right";
    when =
      "explorerViewletCompressedFocus && filesExplorerFocus && foldersViewVisible && !explorerViewletCompressedLastFocus && !inputFocus";
  }
  {
    command = "previousCompressedFolder";
    key = "left";
    when =
      "explorerViewletCompressedFocus && filesExplorerFocus && foldersViewVisible && !explorerViewletCompressedFirstFocus && !inputFocus";
  }
  {
    command = "renameFile";
    key = "ctrl+[KeyT] ctrl+[KeyR]";
    when =
      "filesExplorerFocus && foldersViewVisible && !explorerResourceIsRoot && !explorerResourceReadonly && !inputFocus";
  }
]
