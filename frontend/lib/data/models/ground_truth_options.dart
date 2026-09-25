/// Canonical dropdown values for collector-entered ground truth.
///
/// These are the only valid selections today. Wing, area type, node id/type,
/// local coordinates, and node graph links are intentionally not exposed
/// here; they depend on the future node graph and stay null until then.
const groundTruthCampusOptions = <String>['IIIT K'];

const groundTruthBuildingOptions = <String>[
  'Old Academic Block',
  'New Academic Block',
  'Admin Block',
  'General Pathway',
];

const groundTruthFloorOptions = <String>['Basement', 'Ground', '1', '2'];

const defaultGroundTruthCampus = 'IIIT K';

const lightingConditionOptions = <String>[
  'Unknown',
  'Daylight',
  'Artificial',
  'Mixed',
  'Low light',
];
const crowdLevelOptions = <String>['Unknown', 'None', 'Low', 'Medium', 'High'];
const occlusionLevelOptions = <String>[
  'Unknown',
  'None',
  'Low',
  'Medium',
  'High',
];
const sceneConditionOptions = <String>[
  'Unknown',
  'Clear',
  'Partially obstructed',
  'Obstructed',
];
