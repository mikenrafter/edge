// Input revisions as they stood at one moment: source -> scope -> revision, for
// every catalogued source in one day's stamp window (design 06 1d). A plain
// type in its own file so the derive's prepared day can carry it without
// importing the store.
typedef InputStamp = Map<String, Map<String, int>>;
