/// Public entry point for `aval_player` — the pure-Dart port of the AVAL web
/// player's runtime scheduling core.
///
/// This surface currently covers the Phase 2 foundation modules: the rational
/// clock, decode timeline, edge-lead formula, submission horizon, path
/// sequence builder, and the shared path-scheduler types (with the frozen
/// decoder-worker / runtime-model / worker-sample contracts they reference).
/// The path scheduler itself and the remaining runtime modules are ported in
/// later phases.
library aval_player;

export 'src/asset_catalog.dart';
export 'src/asset_catalog_index.dart';
export 'src/borrowed_avc_inspection.dart';
export 'src/decode_timeline.dart';
export 'src/decoder_worker/client_support.dart';
export 'src/decoder_worker/protocol.dart';
export 'src/edge_lead.dart';
export 'src/errors.dart';
export 'src/model.dart';
export 'src/path_scheduler.dart';
export 'src/path_scheduler_cursor_ledger.dart';
export 'src/path_scheduler_generation.dart';
export 'src/path_scheduler_identity.dart';
export 'src/path_scheduler_model.dart';
export 'src/path_scheduler_output.dart';
export 'src/path_scheduler_pump.dart';
export 'src/path_scheduler_reservation.dart';
export 'src/path_scheduler_resident_runway.dart';
export 'src/path_scheduler_route.dart';
export 'src/path_scheduler_trace.dart';
export 'src/path_scheduler_validation.dart';
export 'src/path_sequence.dart';
export 'src/platform.dart';
export 'src/presentation_ring.dart';
export 'src/rational_time.dart';
export 'src/submission_horizon.dart';
export 'src/verified_blob_store.dart';
export 'src/worker_samples.dart';
