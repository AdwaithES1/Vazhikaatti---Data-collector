class ValidationItem {
  const ValidationItem(this.label, this.valid, this.detail);
  final String label;
  final bool valid;
  final String detail;
}

class MetadataValidator {
  static List<ValidationItem> validate(Map<String, dynamic> data) => [
    ValidationItem(
      'Session name',
      (data['session_name'] as String?)?.trim().isNotEmpty == true,
      'Enter a session name',
    ),
    ValidationItem('Image', data['image_path'] != null, 'A photo is required'),
    ValidationItem(
      'GPS',
      data['latitude'] is num && data['longitude'] is num,
      'Wait for a valid location fix',
    ),
    ValidationItem(
      'GPS accuracy',
      data['gps_accuracy'] is num && (data['gps_accuracy'] as num) <= 30,
      'Move outdoors or wait for accuracy <= 30 m',
    ),
    ValidationItem(
      'Heading',
      data['heading'] is num,
      'Rotate the phone until the compass is available',
    ),
    ValidationItem(
      'Pitch/Roll',
      data['pitch'] is num && data['roll'] is num,
      'Hold the phone steady to read orientation',
    ),
    ValidationItem(
      'Building',
      (data['building_name'] as String?)?.isNotEmpty == true,
      'Select a building',
    ),
    ValidationItem(
      'Floor',
      (data['floor_number'] as String?)?.isNotEmpty == true,
      'Select a floor explicitly',
    ),
    ValidationItem(
      'Capture direction',
      (data['view_direction'] as String?)?.isNotEmpty == true,
      'Choose Front, Right, Back, Left, or Custom',
    ),
    ValidationItem(
      'Dataset type',
      (data['dataset_split'] as String?)?.isNotEmpty == true,
      'Choose reference, query, or test',
    ),
    ValidationItem(
      'Ground truth campus',
      (data['ground_truth_campus'] as String?)?.isNotEmpty == true,
      'Select the ground truth campus',
    ),
    ValidationItem(
      'Ground truth building',
      (data['ground_truth_building'] as String?)?.isNotEmpty == true,
      'Select the ground truth building',
    ),
    ValidationItem(
      'Ground truth floor',
      (data['ground_truth_floor'] as String?)?.isNotEmpty == true,
      'Select the ground truth floor',
    ),
    ValidationItem(
      'Ground truth node name',
      (data['ground_truth_node_name'] as String?)?.trim().isNotEmpty == true,
      'Type the node/location name',
    ),
    ..._coordinateValidation(data),
  ];

  static List<ValidationItem> _coordinateValidation(
    Map<String, dynamic> data,
  ) => [
    for (final field in const [
      'ground_truth_local_x',
      'ground_truth_local_y',
      'ground_truth_local_z',
    ])
      ValidationItem(
        field,
        data[field] == null || data[field] is num,
        'Enter a valid number or leave it empty',
      ),
  ];

  static bool isReady(Map<String, dynamic> data) =>
      validate(data).every((item) => item.valid);
}
