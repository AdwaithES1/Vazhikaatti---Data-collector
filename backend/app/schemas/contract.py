from datetime import datetime
from typing import Any
from pydantic import BaseModel, ConfigDict, Field

class CaptureMetadata(BaseModel):
    model_config = ConfigDict(extra='allow')
    image_path: str | None = None
    image_id: str | None = None
    filename: str | None = None
    dataset_split: str | None = None
    capture_session_id: str | None = None
    session_name: str | None = None
    capture_type: str | None = None
    frame_index: int | None = None
    timestamp: datetime | None = None
    collector_id: str | None = None
    checksum: str | None = None
    campus_id: str | None = None
    campus_name: str | None = None
    building_id: str | None = None
    building_name: str | None = None
    wing_id: str | None = None
    wing_name: str | None = None
    floor_id: str | None = None
    floor_number: str | None = None
    area_id: str | None = None
    area_type: str | None = None
    room_id: str | None = None
    room_name: str | None = None
    node_id: str | None = None
    node_type: str | None = None
    node_name: str | None = None
    local_x: float | None = None
    local_y: float | None = None
    local_z: float | None = None
    coordinate_system_id: str | None = None
    previous_node_id: str | None = None
    next_node_id: str | None = None
    connected_nodes: list[str] | None = None
    latitude: float | None = None
    longitude: float | None = None
    altitude: float | None = None
    gps_accuracy: float | None = None
    gps_timestamp: datetime | None = None
    location_source: str | None = None
    heading: float | None = None
    pitch: float | None = None
    roll: float | None = None
    direction: str | None = None
    view_angle: str | None = None
    camera_facing: str | None = None
    view_direction: str | None = None
    device_make: str | None = None
    device_model: str | None = None
    camera_id: str | None = None
    image_width: int | None = None
    image_height: int | None = None
    focal_length: float | None = None
    focal_length_35mm: float | None = None
    ISO: int | None = None
    exposure_time: str | None = None
    aperture: float | None = None
    white_balance: str | None = None
    flash_used: bool | None = None
    lighting_condition: str | None = None
    crowd_level: str | None = None
    occlusion_level: str | None = None
    artificial_light: bool | None = None
    natural_light: bool | None = None
    scene_condition: str | None = None
    panorama_id: str | None = None
    panorama_sequence_id: str | None = None
    overlap_group_id: str | None = None
    is_panorama_source: bool | None = None
    panorama_status: str | None = None
    sweep_id: str | None = None
    sweep_index: int | None = None
    heading_at_capture: float | None = None
    sweep_trigger_interval_degrees: float | None = None
    sweep_direction: str | None = None
    sweep_total_rotation_degrees: float | None = None
    blur_score: float | None = None
    brightness_score: float | None = None
    contrast_score: float | None = None
    noise_score: float | None = None
    quality_score: float | None = None
    is_blurry: bool | None = None
    is_usable: bool | None = None
    preprocessing_version: str | None = None
    feature_method: str | None = None
    keypoint_count: int | None = None
    descriptor_dimension: int | None = None
    descriptor_file: str | None = None
    reference_image_id: str | None = None
    matching_method: str | None = None
    total_matches: int | None = None
    good_matches: int | None = None
    ratio_test_threshold: float | None = None
    match_score: float | None = None
    geometric_model: str | None = None
    ransac_threshold: float | None = None
    ransac_iterations: int | None = None
    inlier_count: int | None = None
    inlier_ratio: float | None = None
    homography_valid: bool | None = None
    ground_truth_campus: str | None = None
    ground_truth_building: str | None = None
    ground_truth_floor: str | None = None
    ground_truth_node_name: str | None = None
    ground_truth_node: str | None = None
    ground_truth_local_x: float | None = None
    ground_truth_local_y: float | None = None
    ground_truth_local_z: float | None = None
    predicted_building: str | None = None
    predicted_floor: str | None = None
    predicted_node: str | None = None
    predicted_local_x: float | None = None
    predicted_local_y: float | None = None
    localization_confidence: float | None = None
    position_error_m: float | None = None
    building_correct: bool | None = None
    floor_correct: bool | None = None
    node_correct: bool | None = None
    query_time_ms: int | None = None

class CaptureCreate(CaptureMetadata):
    pass

class CaptureResponse(CaptureMetadata):
    pass

class UploadResponse(BaseModel):
    success: bool
    image_id: str
    filename: str
    checksum: str
    duplicate: bool = False
    relative_path: str | None = None

class SessionCreate(BaseModel):
    id: str | None = None
    name: str
    collector_id: str | None = None
    created_at: datetime | None = None
    status: str = 'active'

class SessionResponse(SessionCreate):
    id: str

class NodeCreate(BaseModel):
    id: str
    campus_id: str | None = None
    building_id: str | None = None
    floor_id: str | None = None
    node_id: str
    node_name: str | None = None
    local_x: float | None = None
    local_y: float | None = None
    local_z: float | None = None
    connected_nodes: list[str] = Field(default_factory=list)

class NodeResponse(NodeCreate):
    pass

class DatasetSummary(BaseModel):
    capture_count: int = 0
    session_count: int = 0
    buildings: list[str] = Field(default_factory=list)
    floors: list[str] = Field(default_factory=list)
    nodes: list[str] = Field(default_factory=list)
