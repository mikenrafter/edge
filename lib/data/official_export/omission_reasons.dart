// Reason text recorded by the extras capture, and the stable group it reports under.
// These omissions come from the snapshot itself, so neither the official file
// nor the recovery file holds them.
const kOmitSpace = 'omitted to preserve space for new recordings';
const kOmitUnfinished = 'recording is unfinished';
const kOmitUnsupportedPref = 'unsupported preference type';

String extrasOmissionGroup(String? reason) => switch (reason) {
      kOmitSpace => 'space',
      kOmitUnfinished => 'unfinished',
      kOmitUnsupportedPref => 'value',
      _ => 'unreadable',
    };

/// Groups whose items are in neither saved file.
const kSkippedOmissionGroups = {'space', 'unfinished', 'unreadable', 'value'};
