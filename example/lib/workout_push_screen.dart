import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';

// ---------------------------------------------------------------------------
// Scenario descriptor
// ---------------------------------------------------------------------------
class _Scenario {
  final String label;
  final IconData icon;
  final Color color;
  final List<Map<String, dynamic>> workouts;

  /// When true, the existing 'date' field in each workout is kept as-is
  /// instead of being overwritten with a forward date.
  final bool preserveDates;

  /// How far ahead to schedule each workout relative to now.
  /// Defaults to 2 hours to match Apple WorkoutKit's minimum lookahead.
  final Duration dateOffset;

  const _Scenario({
    required this.label,
    required this.icon,
    required this.color,
    required this.workouts,
    this.preserveDates = false,
    this.dateOffset = const Duration(hours: 2),
  });
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------
class WorkoutPushScreen extends StatefulWidget {
  const WorkoutPushScreen({super.key});

  @override
  State<WorkoutPushScreen> createState() => _WorkoutPushScreenState();
}

class _WorkoutPushScreenState extends State<WorkoutPushScreen> {
  final WorkoutPushManager _pushManager = WorkoutPushManager();
  final TextEditingController _jsonController = TextEditingController();

  bool _isPushing = false;
  WorkoutPushResponse? _lastResponse;
  String? _errorMessage;
  String? _activeScenarioLabel;

  // ── Manage scheduled workouts state ──────────────────────────────────────
  List<ScheduledWorkoutInfo> _scheduledWorkouts = [];
  bool _isLoadingScheduled = false;
  String? _manageMessage;
  final Set<String> _removingIds = {};

  @override
  void dispose() {
    _jsonController.dispose();
    super.dispose();
  }

  // ── Scenario definitions ──────────────────────────────────────────────────

  List<_Scenario> get _scenarios => [
    _Scenario(
      label: 'Mock Interval Run',
      icon: Icons.directions_run,
      color: Colors.blue,
      workouts: [
        {
          'schedule_id': 'mock-interval-run-001',
          'sport': 'RUNNING',
          'summary': {
            'name': 'Mock Interval Run',
            'sport': 'RUNNING',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 300,
              'distance': 508.0,
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 616, 'high': 493},
            },
            {
              'type': 'REPEAT',
              'repeat': 5,
              'duration': 300,
              'distance': 615.0,
              'blocks': [
                {
                  'type': 'INTERVAL',
                  'duration': 30,
                  'distance': 72.0,
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 433, 'high': 391},
                },
                {
                  'type': 'RECOVERY',
                  'duration': 30,
                  'distance': 51.0,
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 616, 'high': 493},
                },
              ],
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 833.0,
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 900, 'high': 600},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Swimming — 25 m Pool (meters)',
      icon: Icons.pool,
      color: Colors.cyan,
      workouts: [
        {
          'schedule_id': 'swim-25m-test-001',
          'sport': 'SWIMMING',
          'distance': 1500.0,
          'duration': 2700,
          'metric_type': 'METRIC',
          'summary': {
            'name': 'Test: 25 m Pool Swim',
            'sport': 'SWIMMING',
            'indoor_outdoor': 'INDOOR',
            'measurement_unit': 'meter',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 300,
              'distance': 200.0,
              'measurement_unit': 'meter',
            },
            {
              'type': 'INTERVAL',
              'duration': 1800,
              'distance': 1000.0,
              'measurement_unit': 'meter',
              'zone_unit': 'HR',
              'target_range': {'low': 130, 'high': 160},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 300.0,
              'measurement_unit': 'meter',
            },
          ],
        },
      ],
    ),
     _Scenario(
      label: 'Swimming — only 25 m Pool (meters)',
      icon: Icons.pool,
      color: Colors.cyan,
      workouts: [
        {
          'schedule_id': 'swim-25m-test-001',
          'sport': 'SWIMMING',
          'distance': 1500.0,
          'duration': 2700,
          'metric_type': 'METRIC',
          'summary': {
            'name': 'Test: 25 m Pool Swim',
            'sport': 'SWIMMING',
            'measurement_unit': 'meter',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 300,
              'distance': 200.0,
              'measurement_unit': 'meter',
            },
            {
              'type': 'INTERVAL',
              'duration': 1800,
              'distance': 1000.0,
              'measurement_unit': 'meter',
              'zone_unit': 'HR',
              'target_range': {'low': 130, 'high': 160},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 300.0,
              'measurement_unit': 'meter',
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Swimming — 25 yd Pool (yards)',
      icon: Icons.pool,
      color: Colors.teal,
      workouts: [
        {
          'schedule_id': 'swim-25y-test-001',
          'sport': 'SWIMMING',
          'distance': 1650.0,
          'duration': 2700,
          'metric_type': 'IMPERIAL',
          'summary': {
            'name': 'Test: 25 yd Pool Swim',
            'sport': 'SWIMMING',
            'indoor_outdoor': 'INDOOR',
            'measurement_unit': 'yard',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 300,
              'distance': 200.0,
              'measurement_unit': 'yard',
            },
            {
              'type': 'INTERVAL',
              'duration': 1800,
              'distance': 1200.0,
              'measurement_unit': 'yard',
              'zone_unit': 'HR',
              'target_range': {'low': 130, 'high': 165},
            },
            {
              'type': 'COOLDOWN',
              'duration': 420,
              'distance': 250.0,
              'measurement_unit': 'yard',
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Swimming — Open Water',
      icon: Icons.waves,
      color: Colors.blue.shade800,
      workouts: [
        {
          'schedule_id': 'swim-ow-test-001',
          'sport': 'SWIMMING',
          'distance': 2000.0,
          'duration': 3600,
          'summary': {
            'name': 'Test: Open Water Swim',
            'sport': 'SWIMMING',
            'indoor_outdoor': 'OUTDOOR',
            'measurement_unit': 'meter',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'distance': 400.0,
              'measurement_unit': 'meter',
            },
            {
              'type': 'INTERVAL',
              'duration': 2400,
              'distance': 1200.0,
              'measurement_unit': 'meter',
              'zone_unit': 'HR',
              'target_range': {'low': 135, 'high': 165},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 400.0,
              'measurement_unit': 'meter',
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Warmup only',
      icon: Icons.whatshot,
      color: Colors.orange,
      workouts: [
        {
          'schedule_id': 'warmup-only-test-001',
          'sport': 'CYCLING',
          'duration': 600,
          'summary': {'name': 'Test: Warmup Only', 'sport': 'CYCLING'},
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 100, 'high': 150},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Cooldown only',
      icon: Icons.ac_unit,
      color: Colors.lightBlue,
      workouts: [
        {
          'schedule_id': 'cooldown-only-test-001',
          'sport': 'CYCLING',
          'duration': 600,
          'summary': {'name': 'Test: Cooldown Only', 'sport': 'CYCLING'},
          'blocks': [
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 85, 'high': 128},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Warmup + Cooldown (no interval)',
      icon: Icons.swap_horiz,
      color: Colors.purple,
      workouts: [
        {
          'schedule_id': 'warmup-cooldown-test-001',
          'sport': 'RUNNING',
          'duration': 1200,
          'summary': {'name': 'Test: Warmup + Cooldown', 'sport': 'RUNNING'},
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 433, 'high': 616},
            },
          
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 493, 'high': 650},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Swimming — Building Endurance in Open Water',
      icon: Icons.fitness_center,
      color: Colors.deepOrange,
      workouts: [
        {"schedule_id":"60149942","date":"2026-05-19T01:15:00Z","sport":"SWIMMING","workout_id":684068,"average_intensity":77,"blocks":[{"block_intent":"WARMUP","cadence_min":0,"distance":85,"duration":180,"equipment_type":"","id":2095424,"intensity":72,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1875,"low":2344},"training_load":1,"type":"WARMUP","zone_unit":"PACE"},{"block_intent":"WARMUP","cadence_min":0,"distance":0,"duration":30,"equipment_type":"","id":2095425,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"},{"block_intent":"WARMUP","cadence_min":0,"distance":101,"duration":180,"equipment_type":"","id":2095426,"intensity":83,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1705,"low":1875},"training_load":2,"type":"WARMUP","zone_unit":"PACE"},{"block_intent":"WARMUP","cadence_min":0,"distance":0,"duration":30,"equipment_type":"","id":2095427,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"},{"block_intent":"WARMUP","cadence_min":0,"distance":109,"duration":180,"equipment_type":"","id":2095428,"intensity":90,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1596,"low":1705},"training_load":3,"type":"WARMUP","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":0,"duration":60,"equipment_type":"","id":2095429,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"},{"blocks":[{"block_intent":"MAINSET","cadence_min":0,"distance":168,"duration":300,"equipment_type":"","id":2095432,"intensity":83,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1705,"low":1875},"training_load":4,"type":"INTERVAL","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":0,"duration":60,"equipment_type":"","id":2095433,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":251,"duration":450,"equipment_type":"","id":2095434,"intensity":83,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1705,"low":1875},"training_load":7,"type":"INTERVAL","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":0,"duration":60,"equipment_type":"","id":2095435,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":335,"duration":600,"equipment_type":"","id":2095436,"intensity":83,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1705,"low":1875},"training_load":9,"type":"INTERVAL","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":0,"duration":120,"equipment_type":"","id":2095437,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"}],"distance":754,"duration":1590,"repeat":1,"training_load":21,"type":"REPEAT"},{"block_intent":"COOLDOWN","cadence_min":0,"distance":142,"duration":300,"equipment_type":"","id":2095431,"intensity":72,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1875,"low":2344},"training_load":3,"type":"COOLDOWN","zone_unit":"PACE"}],"distance":1191,"distance_ri_adjusted":null,"duration":2550,"duration_ri_adjusted":null,"id":29582,"index":0,"summary":{"author_id":null,"description":{"execution":"","fueling":"","general":"This can be adapted to a pool swim. If in open water, be sure to turn back after the 2nd swim and use your cool down to get back to shore.\nBuild your continuous swimming endurance at Z2. \n","purpose":"","tips":"","video_url":""},"elevation":null,"form":false,"measurement_unit":"second","name":"Building endurance in open water v4","sport":"SWIMMING","test_workout":false,"zone_unit":"PACE","tags":"endurance,midd","indoor_outdoor":"INDOOR","index_max":2,"brick":false},"tiz":[480,1530,180,0,0,0,0],"training_load":24,"external_url":null,"workout_chart":[{"duration":180,"intensity":72,"value":2109.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":30,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":180,"intensity":83,"value":1790,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":30,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":180,"intensity":90,"value":1650.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":60,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":300,"intensity":83,"value":1790,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":60,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":450,"intensity":83,"value":1790,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":60,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":600,"intensity":83,"value":1790,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":120,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":300,"intensity":72,"value":2109.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"}],"zone_target":"ENDURANCE","metric_type":"METRIC"}
      ],
    ),
    _Scenario(
      label: 'Swimming — Building Endurance OW v4 (Copy)',
      icon: Icons.pool,
      color: Colors.deepOrange.shade700,
      workouts: [
        {"schedule_id":"60149942-copy","date":"2026-05-19T01:15:00Z","sport":"SWIMMING","workout_id":684068,"average_intensity":77,"blocks":[{"block_intent":"WARMUP","cadence_min":0,"distance":85,"duration":180,"equipment_type":"","id":2095424,"intensity":72,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1875,"low":2344},"training_load":1,"type":"WARMUP","zone_unit":"PACE"},{"block_intent":"WARMUP","cadence_min":0,"distance":0,"duration":30,"equipment_type":"","id":2095425,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"},{"block_intent":"WARMUP","cadence_min":0,"distance":101,"duration":180,"equipment_type":"","id":2095426,"intensity":83,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1705,"low":1875},"training_load":2,"type":"WARMUP","zone_unit":"PACE"},{"block_intent":"WARMUP","cadence_min":0,"distance":0,"duration":30,"equipment_type":"","id":2095427,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"},{"block_intent":"WARMUP","cadence_min":0,"distance":109,"duration":180,"equipment_type":"","id":2095428,"intensity":90,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1596,"low":1705},"training_load":3,"type":"WARMUP","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":0,"duration":60,"equipment_type":"","id":2095429,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"},{"blocks":[{"block_intent":"MAINSET","cadence_min":0,"distance":168,"duration":300,"equipment_type":"","id":2095432,"intensity":83,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1705,"low":1875},"training_load":4,"type":"INTERVAL","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":0,"duration":60,"equipment_type":"","id":2095433,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":251,"duration":450,"equipment_type":"","id":2095434,"intensity":83,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1705,"low":1875},"training_load":7,"type":"INTERVAL","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":0,"duration":60,"equipment_type":"","id":2095435,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":335,"duration":600,"equipment_type":"","id":2095436,"intensity":83,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1705,"low":1875},"training_load":9,"type":"INTERVAL","zone_unit":"PACE"},{"block_intent":"MAINSET","cadence_min":0,"distance":0,"duration":120,"equipment_type":"","id":2095437,"intensity":0,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1515,"low":1596},"training_load":0,"type":"REST","zone_unit":"PACE"}],"distance":754,"duration":1590,"repeat":1,"training_load":21,"type":"REPEAT"},{"block_intent":"COOLDOWN","cadence_min":0,"distance":142,"duration":300,"equipment_type":"","id":2095431,"intensity":72,"measurement_unit":"second","sport":"SWIMMING","target_range":{"high":1875,"low":2344},"training_load":3,"type":"COOLDOWN","zone_unit":"PACE"}],"distance":1191,"distance_ri_adjusted":null,"duration":2550,"duration_ri_adjusted":null,"id":29582,"index":0,"summary":{"author_id":null,"description":{"execution":"","fueling":"","general":"This can be adapted to a pool swim. If in open water, be sure to turn back after the 2nd swim and use your cool down to get back to shore.\nBuild your continuous swimming endurance at Z2. \n","purpose":"","tips":"","video_url":""},"elevation":null,"form":false,"measurement_unit":"second","name":"Building endurance in open water v4","sport":"SWIMMING","test_workout":false,"zone_unit":"PACE","tags":"endurance,midd","indoor_outdoor":"INDOOR","index_max":2,"brick":false},"tiz":[480,1530,180,0,0,0,0],"training_load":24,"external_url":null,"workout_chart":[{"duration":180,"intensity":72,"value":2109.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":30,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":180,"intensity":83,"value":1790,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":30,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":180,"intensity":90,"value":1650.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":60,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":300,"intensity":83,"value":1790,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":60,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":450,"intensity":83,"value":1790,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":60,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":600,"intensity":83,"value":1790,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":120,"intensity":0,"value":1555.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"},{"duration":300,"intensity":72,"value":2109.5,"sport":"SWIMMING","stepPhoto":"https://source.unsplash.com/user/c_v_r/375x250","descriptions":"https://source.unsplash.com/user/c_v_r/375x250"}],"zone_target":"ENDURANCE","metric_type":"METRIC"}
      ],
    ),
    _Scenario(
      label: 'Warmup + Interval + 2 Cooldowns',
      icon: Icons.ac_unit,
      color: Colors.indigo.shade400,
      workouts: [
        {
          'schedule_id': 'multi-cooldown-interval-001',
          'sport': 'CYCLING',
          'duration': 2700,
          'summary': {
            'name': 'Test: Warmup + Interval + 2 Cooldowns',
            'sport': 'CYCLING',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 85, 'high': 128},
            },
            {
              'type': 'INTERVAL',
              'duration': 1200,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 191, 'high': 222},
            },
            {
              'type': 'COOLDOWN',
              'duration': 300,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 100, 'high': 140},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 85, 'high': 128},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: '2 Warmups + 2 Cooldowns (no interval)',
      icon: Icons.swap_vert,
      color: Colors.pink.shade400,
      workouts: [
        {
          'schedule_id': 'multi-warmup-cooldown-001',
          'sport': 'RUNNING',
          'duration': 2100,
          'summary': {
            'name': 'Test: 2 Warmups + 2 Cooldowns',
            'sport': 'RUNNING',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 600, 'high': 480},
            },
            {
              'type': 'WARMUP',
              'duration': 300,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 500, 'high': 420},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 600, 'high': 500},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 720, 'high': 600},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: '2 Cooldowns only',
      icon: Icons.arrow_downward,
      color: Colors.cyan.shade700,
      workouts: [
        {
          'schedule_id': 'multi-cooldown-only-001',
          'sport': 'CYCLING',
          'duration': 1100,
          'summary': {
            'name': 'Test: 2 Cooldowns Only',
            'sport': 'CYCLING',
          },
          'blocks': [
            {
              'type': 'COOLDOWN',
              'duration': 500,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 100, 'high': 140},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 85, 'high': 128},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: '2 Warmups only',
      icon: Icons.arrow_upward,
      color: Colors.orange.shade700,
      workouts: [
        {
          'schedule_id': 'multi-warmup-only-001',
          'sport': 'CYCLING',
          'duration': 1100,
          'summary': {
            'name': 'Test: 2 Warmups Only',
            'sport': 'CYCLING',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 85, 'high': 128},
            },
            {
              'type': 'WARMUP',
              'duration': 500,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 100, 'high': 150},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Warmup + 2 Cooldowns (no interval)',
      icon: Icons.vertical_align_bottom,
      color: Colors.teal.shade400,
      workouts: [
        {
          'schedule_id': 'warmup-multi-cooldown-001',
          'sport': 'RUNNING',
          'duration': 1700,
          'summary': {
            'name': 'Test: Warmup + 2 Cooldowns',
            'sport': 'RUNNING',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 600, 'high': 480},
            },
            {
              'type': 'COOLDOWN',
              'duration': 500,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 600, 'high': 500},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 720, 'high': 600},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Warmup + Interval (no cooldown)',
      icon: Icons.trending_up,
      color: Colors.green,
      workouts: [
        {
          'schedule_id': 'warmup-interval-test-001',
          'sport': 'CYCLING',
          'duration': 1800,
          'summary': {'name': 'Test: Warmup + Interval', 'sport': 'CYCLING'},
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 85, 'high': 128},
            },
            {
              'type': 'INTERVAL',
              'duration': 1200,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 191, 'high': 222},
            },
          ],
        },
      ],
    ),
    // ── Unit display scenarios ────────────────────────────────────────────
    _Scenario(
      label: 'Run — display in Miles',
      icon: Icons.directions_run,
      color: Colors.indigo,
      workouts: [
        {
          'schedule_id': 'run-unit-mile-001',
          'sport': 'RUNNING',
          'unit': 'mile',
          'summary': {
            'name': 'Run: Goal in Miles',
            'sport': 'RUNNING',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'distance': 805.0, // ~0.5 mi in meters
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 600, 'high': 480},
            },
            {
              'type': 'REPEAT',
              'repeat': 3,
              'duration': 960,
              'distance': 1609.0, // ~1 mi in meters
              'blocks': [
                {
                  'type': 'INTERVAL',
                  'duration': 480,
                  'distance': 1609.0, // 1 mi in meters → displayed as 1 mi
                  'measurement_unit': 'meter',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 360, 'high': 330},
                },
                {
                  'type': 'RECOVERY',
                  'duration': 120,
                  'distance': 402.0, // ~0.25 mi in meters
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 720, 'high': 540},
                },
              ],
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 805.0, // ~0.5 mi in meters
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 900, 'high': 600},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Run — display in Kilometres',
      icon: Icons.directions_run,
      color: Colors.teal.shade700,
      workouts: [
        {
          'schedule_id': 'run-unit-km-001',
          'sport': 'RUNNING',
          'unit': 'km',
          'summary': {
            'name': 'Run: Goal in Kilometres',
            'sport': 'RUNNING',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'distance': 1000.0, // 1 km in meters
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 600, 'high': 480},
            },
            {
              'type': 'REPEAT',
              'repeat': 4,
              'duration': 720,
              'distance': 1000.0,
              'blocks': [
                {
                  'type': 'INTERVAL',
                  'duration': 300,
                  'distance': 1000.0, // 1 km in meters → displayed as 1 km
                  'measurement_unit': 'meter',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 300, 'high': 270},
                },
                {
                  'type': 'RECOVERY',
                  'duration': 120,
                  'distance': 400.0,
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 720, 'high': 540},
                },
              ],
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 1000.0,
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 900, 'high': 600},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Run — display in Meters',
      icon: Icons.directions_run,
      color: Colors.brown,
      workouts: [
        {
          'schedule_id': 'run-unit-meter-001',
          'sport': 'RUNNING',
          'unit': 'meter',
          'summary': {
            'name': 'Run: Goal in Meters',
            'sport': 'RUNNING',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'distance': 800.0,
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 600, 'high': 480},
            },
            {
              'type': 'REPEAT',
              'repeat': 5,
              'duration': 600,
              'distance': 800.0,
              'blocks': [
                {
                  'type': 'INTERVAL',
                  'duration': 240,
                  'distance': 800.0, // 800 m → displayed as 800 m
                  'measurement_unit': 'meter',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 270, 'high': 240},
                },
                {
                  'type': 'RECOVERY',
                  'duration': 120,
                  'distance': 200.0,
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 720, 'high': 540},
                },
              ],
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 800.0,
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 900, 'high': 600},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Run — display in Yards',
      icon: Icons.directions_run,
      color: Colors.amber.shade800,
      workouts: [
        {
          'schedule_id': 'run-unit-yard-001',
          'sport': 'RUNNING',
          'unit': 'yard',
          'summary': {
            'name': 'Run: Goal in Yards',
            'sport': 'RUNNING',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'distance': 457.2, // 500 yd in meters
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 600, 'high': 480},
            },
            {
              'type': 'REPEAT',
              'repeat': 6,
              'duration': 540,
              'distance': 411.5,
              'blocks': [
                {
                  'type': 'INTERVAL',
                  'duration': 240,
                  'distance':
                      411.5, // ~440 yd (quarter mile) in meters → displayed as 440 yd
                  'measurement_unit': 'meter',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 270, 'high': 240},
                },
                {
                  'type': 'RECOVERY',
                  'duration': 120,
                  'distance': 91.4, // 100 yd in meters
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 720, 'high': 540},
                },
              ],
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 457.2, // 500 yd in meters
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 900, 'high': 600},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Cycling — display in Kilometres',
      icon: Icons.directions_bike,
      color: Colors.green.shade700,
      workouts: [
        {
          'schedule_id': 'cycle-unit-km-001',
          'sport': 'CYCLING',
          'unit': 'km',
          'summary': {
            'name': 'Cycling: Goal in Kilometres',
            'sport': 'CYCLING',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'distance': 5000.0, // 5 km in meters
              'measurement_unit': 'second',
              'sport': 'CYCLING',
              'zone_unit': 'POWER',
              'target_range': {'low': 100, 'high': 150},
            },
            {
              'type': 'REPEAT',
              'repeat': 4,
              'duration': 900,
              'distance': 10000.0,
              'blocks': [
                {
                  'type': 'INTERVAL',
                  'duration': 600,
                  'distance': 10000.0, // 10 km in meters → displayed as 10 km
                  'measurement_unit': 'meter',
                  'sport': 'CYCLING',
                  'zone_unit': 'POWER',
                  'target_range': {'low': 220, 'high': 270},
                },
                {
                  'type': 'RECOVERY',
                  'duration': 180,
                  'distance': 2500.0,
                  'measurement_unit': 'second',
                  'sport': 'CYCLING',
                  'zone_unit': 'POWER',
                  'target_range': {'low': 80, 'high': 120},
                },
              ],
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 5000.0,
              'measurement_unit': 'second',
              'sport': 'CYCLING',
              'zone_unit': 'POWER',
              'target_range': {'low': 80, 'high': 120},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Cycling — display in Miles',
      icon: Icons.directions_bike,
      color: Colors.red.shade700,
      workouts: [
        {
          'schedule_id': 'cycle-unit-mile-001',
          'sport': 'CYCLING',
          'unit': 'mile',
          'summary': {
            'name': 'Cycling: Goal in Miles',
            'sport': 'CYCLING',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'distance': 4828.0, // ~3 mi in meters
              'measurement_unit': 'second',
              'sport': 'CYCLING',
              'zone_unit': 'POWER',
              'target_range': {'low': 100, 'high': 150},
            },
            {
              'type': 'REPEAT',
              'repeat': 3,
              'duration': 1200,
              'distance': 16093.0,
              'blocks': [
                {
                  'type': 'INTERVAL',
                  'duration': 900,
                  'distance': 16093.0, // ~10 mi in meters → displayed as 10 mi
                  'measurement_unit': 'meter',
                  'sport': 'CYCLING',
                  'zone_unit': 'POWER',
                  'target_range': {'low': 220, 'high': 270},
                },
                {
                  'type': 'RECOVERY',
                  'duration': 300,
                  'distance': 3218.0, // ~2 mi in meters
                  'measurement_unit': 'second',
                  'sport': 'CYCLING',
                  'zone_unit': 'POWER',
                  'target_range': {'low': 80, 'high': 120},
                },
              ],
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 4828.0, // ~3 mi in meters
              'measurement_unit': 'second',
              'sport': 'CYCLING',
              'zone_unit': 'POWER',
              'target_range': {'low': 80, 'high': 120},
            },
          ],
        },
      ],
    ),
    // ── End unit display scenarios ─────────────────────────────────────────
    // ── Indoor / Outdoor location scenarios ───────────────────────────────
    _Scenario(
      label: 'Outdoor Running',
      icon: Icons.directions_run,
      color: Colors.lightGreen.shade700,
      workouts: [
        {
          'schedule_id': 'run-outdoor-test-001',
          'sport': 'RUNNING',
          'duration': 1800,
          'distance': 5000.0,
          'summary': {
            'name': 'Test: Outdoor Run',
            'sport': 'RUNNING',
            'indoor_outdoor': 'OUTDOOR',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 300,
              'distance': 800.0,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 600, 'high': 480},
            },
            {
              'type': 'INTERVAL',
              'duration': 1200,
              'distance': 3500.0,
              'measurement_unit': 'second',
              'zone_unit': 'HR',
              'target_range': {'low': 140, 'high': 165},
            },
            {
              'type': 'COOLDOWN',
              'duration': 300,
              'distance': 700.0,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 720, 'high': 540},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Indoor Running (Treadmill)',
      icon: Icons.directions_run,
      color: Colors.deepPurple.shade400,
      workouts: [
        {
          'schedule_id': 'run-indoor-test-001',
          'sport': 'RUNNING',
          'duration': 1800,
          'summary': {
            'name': 'Test: Indoor Run',
            'sport': 'RUNNING',
            'indoor_outdoor': 'INDOOR',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 300,
              'measurement_unit': 'second',
              'zone_unit': 'HR',
              'target_range': {'low': 110, 'high': 130},
            },
            {
              'type': 'INTERVAL',
              'duration': 1200,
              'measurement_unit': 'second',
              'zone_unit': 'HR',
              'target_range': {'low': 140, 'high': 165},
            },
            {
              'type': 'COOLDOWN',
              'duration': 300,
              'measurement_unit': 'second',
              'zone_unit': 'HR',
              'target_range': {'low': 100, 'high': 125},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Outdoor Cycling',
      icon: Icons.directions_bike,
      color: Colors.blueGrey.shade700,
      workouts: [
        {
          'schedule_id': 'cycle-outdoor-test-001',
          'sport': 'CYCLING',
          'duration': 2700,
          'distance': 20000.0,
          'summary': {
            'name': 'Test: Outdoor Cycle',
            'sport': 'CYCLING',
            'indoor_outdoor': 'OUTDOOR',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'distance': 4000.0,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 100, 'high': 150},
            },
            {
              'type': 'INTERVAL',
              'duration': 1500,
              'distance': 13000.0,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 200, 'high': 260},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 3000.0,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 80, 'high': 120},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Indoor Cycling (Trainer)',
      icon: Icons.directions_bike,
      color: Colors.pink.shade700,
      workouts: [
        {
          'schedule_id': 'cycle-indoor-test-001',
          'sport': 'CYCLING',
          'duration': 2700,
          'summary': {
            'name': 'Test: Indoor Cycle',
            'sport': 'CYCLING',
            'indoor_outdoor': 'INDOOR',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 100, 'high': 150},
            },
            {
              'type': 'INTERVAL',
              'duration': 1500,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 200, 'high': 260},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 80, 'high': 120},
            },
          ],
        },
      ],
    ),
    // ── End indoor / outdoor location scenarios ───────────────────────────
    _Scenario(
      label: '1 Mile Tempo (Real Workout)',
      icon: Icons.route,
      color: Colors.deepPurple,
      workouts: [
        {
          'average_intensity': 75,
          'blocks': [
            {
              'description': 'Aim to reach Z2 by the end of your warm up',
              'distance': 550.0,
              'duration': 300,
              'equipment_type': '',
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'target_range': {'high': 434, 'low': 720},
              'training_load': 3,
              'type': 'WARMUP',
              'zone_target': {
                'range': {'focus_max_range': 83, 'focus_min_range': 50},
              },
              'zone_unit': 'PACE',
            },
            {
              'distance': 625.0,
              'duration': 300,
              'equipment_type': '',
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'target_range': {'high': 434, 'low': 492},
              'training_load': 4,
              'type': 'WARMUP',
              'zone_target': {'zone': 'ENDURANCE'},
              'zone_unit': 'PACE',
            },
            {
              'blocks': [
                {
                  'description': 'Build to Threshold',
                  'distance': 82.0,
                  'duration': 30,
                  'equipment_type': '',
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'target_range': {'high': 364, 'low': 390},
                  'training_load': 0,
                  'type': 'INTERVAL',
                  'zone_target': {'zone': 'THRESHOLD'},
                  'zone_unit': 'PACE',
                },
                {
                  'description': 'Super Easy - walking is fine',
                  'distance': 39.0,
                  'duration': 30,
                  'equipment_type': '',
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'target_range': {'high': 554, 'low': 1200},
                  'training_load': 0,
                  'type': 'RECOVERY',
                  'zone_target': {
                    'range': {'focus_max_range': 65, 'focus_min_range': 30},
                  },
                  'zone_unit': 'PACE',
                },
              ],
              'distance': 605.0,
              'duration': 300,
              'repeat': 5,
              'training_load': 4,
              'type': 'REPEAT',
            },
            {
              'blocks': [
                {
                  'distance': 1609.0,
                  'duration': 666,
                  'equipment_type': '',
                  'measurement_unit': 'meter',
                  'sport': 'RUNNING',
                  'target_range': {'high': 391, 'low': 433},
                  'training_load': 14,
                  'type': 'INTERVAL',
                  'zone_target': {'zone': 'TEMPO'},
                  'zone_unit': 'PACE',
                },
                {
                  'description': 'Very easy for maximum recovery',
                  'distance': 365.76,
                  'duration': 216,
                  'equipment_type': '',
                  'measurement_unit': 'meter',
                  'sport': 'RUNNING',
                  'target_range': {'high': 493, 'low': 616},
                  'training_load': 2,
                  'type': 'RECOVERY',
                  'zone_target': {'zone': 'RECOVERY'},
                  'zone_unit': 'PACE',
                },
              ],
              'distance': 3949.52,
              'duration': 1764,
              'repeat': 2,
              'training_load': 32,
              'type': 'REPEAT',
            },
            {
              'description':
                  'Gradually lower heart rate to Z1 by the end of your warm down',
              'distance': 1017.0,
              'duration': 600,
              'equipment_type': '',
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'target_range': {'high': 493, 'low': 616},
              'training_load': 6,
              'type': 'COOLDOWN',
              'zone_target': {'zone': 'RECOVERY'},
              'zone_unit': 'PACE',
            },
          ],
          'brick_summaries': [],
          'distance': 6746.52,
          'distance_ri_adjusted': 4895.57,
          'duration': 3264,
          'duration_ri_adjusted': 1006.5,
          'id': 16314,
          'index': 0,
          'priority': 0,
          'sport': 'RUNNING',
          'summary': {
            'brick': false,
            'description': {
              'general':
                  'This workout will build your ability to work at higher intensity for longer periods without fatigue impacting your output. Settle into these 1 mile Z3 efforts while focusing on a steady and deliberate breathing rate.',
            },
            'elevation': 'FLAT',
            'form': false,
            'index_max': 9,
            'measurement_unit': 'meter',
            'name': '1 mile tempo',
            'sport': 'RUNNING',
            'tags': '',
            'test_workout': false,
            'zone_unit': 'PACE',
          },
          'training_load': 51,
          'workout_id': 116246,
          'zone_target': 'TEMPO',
          'schedule_id': '9e917486-147c-4b1c-861d-a2278a3c9719',
        },
      ],
    ),
    _Scenario(
      label: 'HPH Hiking Tempo Intervals',
      icon: Icons.hiking,
      color: Colors.green.shade800,
      dateOffset: const Duration(minutes: 15),
      workouts: [
        {
          'schedule_id': '46002051',
          'sport': 'HIKING',
          'average_intensity': 66,
          'blocks': [
            {
              'block_intent': 'WARMUP',
              'cadence_min': 0,
              'distance': 0,
              'duration': 1200,
              'equipment_type': '',
              'id': 902152,
              'intensity': 65,
              'measurement_unit': 'second',
              'sport': 'HIKING',
              'target_range': {'high': 148, 'low': 137},
              'training_load': 14,
              'type': 'WARMUP',
              'zone_unit': 'HR',
            },
            {
              'blocks': [
                {
                  'block_intent': 'MAINSET',
                  'cadence_min': 0,
                  'distance': 0,
                  'duration': 600,
                  'equipment_type': '',
                  'id': 902155,
                  'intensity': 75,
                  'measurement_unit': 'second',
                  'sport': 'HIKING',
                  'target_range': {'high': 160, 'low': 148},
                  'training_load': 9,
                  'type': 'INTERVAL',
                  'zone_unit': 'HR',
                },
                {
                  'block_intent': 'MAINSET',
                  'cadence_min': 0,
                  'description':
                      'During the recovery periods between intervals, reduce effort and allow heart rate to drop',
                  'distance': 0,
                  'duration': 180,
                  'equipment_type': '',
                  'id': 902156,
                  'intensity': 54,
                  'measurement_unit': 'second',
                  'sport': 'HIKING',
                  'target_range': {'high': 137, 'low': 110},
                  'training_load': 1,
                  'type': 'RECOVERY',
                  'zone_unit': 'HR',
                },
              ],
              'distance': 0,
              'duration': 1560,
              'repeat': 2,
              'training_load': 21,
              'type': 'REPEAT',
            },
            {
              'block_intent': 'COOLDOWN',
              'cadence_min': 0,
              'distance': 0,
              'duration': 600,
              'equipment_type': '',
              'id': 902154,
              'intensity': 54,
              'measurement_unit': 'second',
              'sport': 'HIKING',
              'target_range': {'high': 137, 'low': 110},
              'training_load': 4,
              'type': 'COOLDOWN',
              'zone_unit': 'HR',
            },
          ],
          'brick_summaries': [],
          'distance': 0,
          'duration': 3360,
          'id': 32460,
          'index': 0,
          'intent': 'INTERVALS',
          'interval_target': false,
          'main_duration': 1560,
          'main_tiz': [360, 0, 1200, 0, 0, 0, 0],
          'priority': 0,
          'summary': {
            'brick': false,
            'description': {
              'execution': '',
              'fueling': '',
              'general':
                  'During the recovery periods between intervals, reduce effort and allow heart rate to drop',
              'purpose': '',
              'tips': '',
              'video_url': '',
            },
            'form': false,
            'index_max': 7,
            'measurement_unit': 'second',
            'name': 'HPH Longevity - 10min tempo intervals cardio (L)',
            'private': false,
            'sport': 'HIKING',
            'tags': '',
            'test_workout': false,
            'zone_unit': 'HR',
          },
          'tiz': [960, 1200, 1200, 0, 0, 0, 0],
          'training_load': 40,
          'workout_chart': [
            {
              'duration': 1200,
              'intensity': 65,
              'sport': 'HIKING',
              'value': 142.5,
            },
            {
              'duration': 600,
              'intensity': 75,
              'sport': 'HIKING',
              'value': 154.0,
            },
            {
              'duration': 180,
              'intensity': 54,
              'sport': 'HIKING',
              'value': 123.5,
            },
            {
              'duration': 600,
              'intensity': 75,
              'sport': 'HIKING',
              'value': 154.0,
            },
            {
              'duration': 180,
              'intensity': 54,
              'sport': 'HIKING',
              'value': 123.5,
            },
            {
              'duration': 600,
              'intensity': 54,
              'sport': 'HIKING',
              'value': 123.5,
            },
          ],
          'workout_id': 902151,
          'zone_target': 'TEMPO',
        },
      ],
    ),
    _Scenario(
      label: 'HPH Elliptical Tempo Intervals',
      icon: Icons.directions_walk,
      color: Colors.deepOrange.shade700,
      dateOffset: const Duration(minutes: 15),
      workouts: [
        {
          'schedule_id': '46002052',
          'sport': 'ELLIPTICAL',
          'average_intensity': 66,
          'blocks': [
            {
              'block_intent': 'WARMUP',
              'cadence_min': 0,
              'distance': 0,
              'duration': 1200,
              'equipment_type': '',
              'id': 902140,
              'intensity': 65,
              'measurement_unit': 'second',
              'sport': 'ELLIPTICAL',
              'target_range': {'high': 148, 'low': 137},
              'training_load': 14,
              'type': 'WARMUP',
              'zone_unit': 'HR',
            },
            {
              'blocks': [
                {
                  'block_intent': 'MAINSET',
                  'cadence_min': 0,
                  'distance': 0,
                  'duration': 600,
                  'equipment_type': '',
                  'id': 902143,
                  'intensity': 75,
                  'measurement_unit': 'second',
                  'sport': 'ELLIPTICAL',
                  'target_range': {'high': 160, 'low': 148},
                  'training_load': 9,
                  'type': 'INTERVAL',
                  'zone_unit': 'HR',
                },
                {
                  'block_intent': 'MAINSET',
                  'cadence_min': 0,
                  'description':
                      'During the recovery periods between intervals, reduce effort and allow heart rate to drop',
                  'distance': 0,
                  'duration': 180,
                  'equipment_type': '',
                  'id': 902144,
                  'intensity': 54,
                  'measurement_unit': 'second',
                  'sport': 'ELLIPTICAL',
                  'target_range': {'high': 137, 'low': 110},
                  'training_load': 1,
                  'type': 'RECOVERY',
                  'zone_unit': 'HR',
                },
              ],
              'distance': 0,
              'duration': 1560,
              'repeat': 2,
              'training_load': 21,
              'type': 'REPEAT',
            },
            {
              'block_intent': 'COOLDOWN',
              'cadence_min': 0,
              'distance': 0,
              'duration': 600,
              'equipment_type': '',
              'id': 902142,
              'intensity': 54,
              'measurement_unit': 'second',
              'sport': 'ELLIPTICAL',
              'target_range': {'high': 137, 'low': 110},
              'training_load': 4,
              'type': 'COOLDOWN',
              'zone_unit': 'HR',
            },
          ],
          'brick_summaries': [],
          'distance': 0,
          'duration': 3360,
          'id': 32446,
          'index': 0,
          'intent': 'INTERVALS',
          'interval_target': false,
          'main_duration': 1560,
          'main_tiz': [360, 0, 1200, 0, 0, 0, 0],
          'priority': 0,
          'summary': {
            'brick': false,
            'description': {
              'execution': '',
              'fueling': '',
              'general':
                  'During the recovery periods between intervals, reduce effort and allow heart rate to drop',
              'purpose': '',
              'tips': '',
              'video_url': '',
            },
            'form': false,
            'index_max': 7,
            'measurement_unit': 'second',
            'name': 'HPH Longevity - 10min tempo intervals cardio (L)',
            'private': false,
            'sport': 'ELLIPTICAL',
            'tags': '',
            'test_workout': false,
            'zone_unit': 'HR',
          },
          'tiz': [960, 1200, 1200, 0, 0, 0, 0],
          'training_load': 40,
          'workout_chart': [
            {
              'duration': 1200,
              'intensity': 65,
              'sport': 'ELLIPTICAL',
              'value': 142.5,
            },
            {
              'duration': 600,
              'intensity': 75,
              'sport': 'ELLIPTICAL',
              'value': 154.0,
            },
            {
              'duration': 180,
              'intensity': 54,
              'sport': 'ELLIPTICAL',
              'value': 123.5,
            },
            {
              'duration': 600,
              'intensity': 75,
              'sport': 'ELLIPTICAL',
              'value': 154.0,
            },
            {
              'duration': 180,
              'intensity': 54,
              'sport': 'ELLIPTICAL',
              'value': 123.5,
            },
            {
              'duration': 600,
              'intensity': 54,
              'sport': 'ELLIPTICAL',
              'value': 123.5,
            },
          ],
          'workout_id': 902139,
          'zone_target': 'TEMPO',
        },
      ],
    ),
    _Scenario(
      label: 'HPH Rowing Tempo Intervals',
      icon: Icons.rowing,
      color: Colors.blue.shade800,
      dateOffset: const Duration(minutes: 15),
      workouts: [
        {
          'schedule_id': '46002053',
          'sport': 'ROWING',
          'average_intensity': 66,
          'blocks': [
            {
              'block_intent': 'WARMUP',
              'cadence_min': 0,
              'distance': 0,
              'duration': 1200,
              'equipment_type': '',
              'id': 902134,
              'intensity': 65,
              'measurement_unit': 'second',
              'sport': 'ROWING',
              'target_range': {'high': 148, 'low': 137},
              'training_load': 14,
              'type': 'WARMUP',
              'zone_unit': 'HR',
            },
            {
              'blocks': [
                {
                  'block_intent': 'MAINSET',
                  'cadence_min': 0,
                  'distance': 0,
                  'duration': 600,
                  'equipment_type': '',
                  'id': 902137,
                  'intensity': 75,
                  'measurement_unit': 'second',
                  'sport': 'ROWING',
                  'target_range': {'high': 160, 'low': 148},
                  'training_load': 9,
                  'type': 'INTERVAL',
                  'zone_unit': 'HR',
                },
                {
                  'block_intent': 'MAINSET',
                  'cadence_min': 0,
                  'description':
                      'During the recovery periods between intervals, reduce effort and allow heart rate to drop',
                  'distance': 0,
                  'duration': 180,
                  'equipment_type': '',
                  'id': 902138,
                  'intensity': 54,
                  'measurement_unit': 'second',
                  'sport': 'ROWING',
                  'target_range': {'high': 137, 'low': 110},
                  'training_load': 1,
                  'type': 'RECOVERY',
                  'zone_unit': 'HR',
                },
              ],
              'distance': 0,
              'duration': 1560,
              'repeat': 2,
              'training_load': 21,
              'type': 'REPEAT',
            },
            {
              'block_intent': 'COOLDOWN',
              'cadence_min': 0,
              'distance': 0,
              'duration': 600,
              'equipment_type': '',
              'id': 902136,
              'intensity': 54,
              'measurement_unit': 'second',
              'sport': 'ROWING',
              'target_range': {'high': 137, 'low': 110},
              'training_load': 4,
              'type': 'COOLDOWN',
              'zone_unit': 'HR',
            },
          ],
          'brick_summaries': [],
          'distance': 0,
          'duration': 3360,
          'id': 32439,
          'index': 0,
          'intent': 'INTERVALS',
          'interval_target': false,
          'main_duration': 1560,
          'main_tiz': [360, 0, 1200, 0, 0, 0, 0],
          'priority': 0,
          'summary': {
            'brick': false,
            'description': {
              'execution': '',
              'fueling': '',
              'general':
                  'During the recovery periods between intervals, reduce effort and allow heart rate to drop',
              'purpose': '',
              'tips': '',
              'video_url': '',
            },
            'form': false,
            'index_max': 7,
            'measurement_unit': 'second',
            'name': 'HPH Longevity - 10min tempo intervals cardio (L)',
            'private': false,
            'sport': 'ROWING',
            'tags': '',
            'test_workout': false,
            'zone_unit': 'HR',
          },
          'tiz': [960, 1200, 1200, 0, 0, 0, 0],
          'training_load': 40,
          'workout_chart': [
            {
              'duration': 1200,
              'intensity': 65,
              'sport': 'ROWING',
              'value': 142.5,
            },
            {
              'duration': 600,
              'intensity': 75,
              'sport': 'ROWING',
              'value': 154.0,
            },
            {
              'duration': 180,
              'intensity': 54,
              'sport': 'ROWING',
              'value': 123.5,
            },
            {
              'duration': 600,
              'intensity': 75,
              'sport': 'ROWING',
              'value': 154.0,
            },
            {
              'duration': 180,
              'intensity': 54,
              'sport': 'ROWING',
              'value': 123.5,
            },
            {
              'duration': 600,
              'intensity': 54,
              'sport': 'ROWING',
              'value': 123.5,
            },
          ],
          'workout_id': 902133,
          'zone_target': 'TEMPO',
        },
      ],
    ),
    _Scenario(
      label: 'HPH Tempo Intervals',
      icon: Icons.bolt,
      color: Colors.orange.shade800,
      dateOffset: const Duration(minutes: 15),
      workouts: [
        {
          'schedule_id': '46002054',
          'sport': 'RUNNING',
          'average_intensity': 66,
          'blocks': [
            {
              'block_intent': 'WARMUP',
              'cadence_min': 0,
              'distance': 0,
              'duration': 1200,
              'equipment_type': '',
              'id': 902146,
              'intensity': 65,
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'target_range': {'high': 148, 'low': 137},
              'training_load': 14,
              'type': 'WARMUP',
              'zone_unit': 'HR',
            },
            {
              'blocks': [
                {
                  'block_intent': 'MAINSET',
                  'cadence_min': 0,
                  'distance': 0,
                  'duration': 600,
                  'equipment_type': '',
                  'id': 902149,
                  'intensity': 75,
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'target_range': {'high': 160, 'low': 148},
                  'training_load': 9,
                  'type': 'INTERVAL',
                  'zone_unit': 'HR',
                },
                {
                  'block_intent': 'MAINSET',
                  'cadence_min': 0,
                  'description':
                      'During the recovery periods between intervals, reduce effort and allow heart rate to drop',
                  'distance': 0,
                  'duration': 180,
                  'equipment_type': '',
                  'id': 902150,
                  'intensity': 54,
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'target_range': {'high': 137, 'low': 110},
                  'training_load': 1,
                  'type': 'RECOVERY',
                  'zone_unit': 'HR',
                },
              ],
              'distance': 0,
              'duration': 1560,
              'repeat': 2,
              'training_load': 21,
              'type': 'REPEAT',
            },
            {
              'block_intent': 'COOLDOWN',
              'cadence_min': 0,
              'distance': 0,
              'duration': 600,
              'equipment_type': '',
              'id': 902148,
              'intensity': 54,
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'target_range': {'high': 137, 'low': 110},
              'training_load': 4,
              'type': 'COOLDOWN',
              'zone_unit': 'HR',
            },
          ],
          'brick_summaries': [],
          'distance': 0,
          'duration': 3360,
          'id': 32453,
          'index': 0,
          'intent': 'INTERVALS',
          'interval_target': false,
          'main_duration': 1560,
          'main_tiz': [360, 0, 1200, 0, 0, 0, 0],
          'priority': 0,
          'summary': {
            'brick': false,
            'description': {
              'execution': '',
              'fueling': '',
              'general':
                  'During the recovery periods between intervals, reduce effort and allow heart rate to drop',
              'purpose': '',
              'tips': '',
              'video_url': '',
            },
            'form': false,
            'index_max': 7,
            'measurement_unit': 'second',
            'name': 'HPH Longevity - 10min tempo intervals cardio (L)',
            'private': false,
            'sport': 'RUNNING',
            'tags': '',
            'test_workout': false,
            'zone_unit': 'HR',
          },
          'tiz': [960, 1200, 1200, 0, 0, 0, 0],
          'training_load': 40,
          'workout_chart': [
            {
              'duration': 1200,
              'intensity': 65,
              'sport': 'RUNNING',
              'value': 142.5,
            },
            {'duration': 600, 'intensity': 75, 'sport': 'RUNNING', 'value': 154.0},
            {'duration': 180, 'intensity': 54, 'sport': 'RUNNING', 'value': 123.5},
            {'duration': 600, 'intensity': 75, 'sport': 'RUNNING', 'value': 154.0},
            {'duration': 180, 'intensity': 54, 'sport': 'RUNNING', 'value': 123.5},
            {'duration': 600, 'intensity': 54, 'sport': 'RUNNING', 'value': 123.5},
          ],
          'workout_id': 902145,
          'zone_target': 'TEMPO',
        },
      ],
    ),
    _Scenario(
      label: 'HPH Walking Tempo Intervals',
      icon: Icons.directions_walk,
      color: Colors.teal.shade600,
      dateOffset: const Duration(minutes: 15),
      workouts: [
        {
          'schedule_id': '46002055',
          'sport': 'WALKING',
          'average_intensity': 66,
          'blocks': [
            {
              'block_intent': 'WARMUP',
              'cadence_min': 0,
              'distance': 0,
              'duration': 1200,
              'equipment_type': '',
              'id': 902128,
              'intensity': 65,
              'measurement_unit': 'second',
              'sport': 'WALKING',
              'target_range': {'high': 148, 'low': 137},
              'training_load': 14,
              'type': 'WARMUP',
              'zone_unit': 'HR',
            },
            {
              'blocks': [
                {
                  'block_intent': 'MAINSET',
                  'cadence_min': 0,
                  'distance': 0,
                  'duration': 600,
                  'equipment_type': '',
                  'id': 902131,
                  'intensity': 75,
                  'measurement_unit': 'second',
                  'sport': 'WALKING',
                  'target_range': {'high': 160, 'low': 148},
                  'training_load': 9,
                  'type': 'INTERVAL',
                  'zone_unit': 'HR',
                },
                {
                  'block_intent': 'MAINSET',
                  'cadence_min': 0,
                  'description':
                      'During the recovery periods between intervals, reduce effort and allow heart rate to drop',
                  'distance': 0,
                  'duration': 180,
                  'equipment_type': '',
                  'id': 902132,
                  'intensity': 54,
                  'measurement_unit': 'second',
                  'sport': 'WALKING',
                  'target_range': {'high': 137, 'low': 110},
                  'training_load': 1,
                  'type': 'RECOVERY',
                  'zone_unit': 'HR',
                },
              ],
              'distance': 0,
              'duration': 1560,
              'repeat': 2,
              'training_load': 21,
              'type': 'REPEAT',
            },
            {
              'block_intent': 'COOLDOWN',
              'cadence_min': 0,
              'distance': 0,
              'duration': 600,
              'equipment_type': '',
              'id': 902130,
              'intensity': 54,
              'measurement_unit': 'second',
              'sport': 'WALKING',
              'target_range': {'high': 137, 'low': 110},
              'training_load': 4,
              'type': 'COOLDOWN',
              'zone_unit': 'HR',
            },
          ],
          'brick_summaries': [],
          'distance': 0,
          'duration': 3360,
          'id': 32432,
          'index': 0,
          'intent': 'INTERVALS',
          'interval_target': false,
          'main_duration': 1560,
          'main_tiz': [360, 0, 1200, 0, 0, 0, 0],
          'priority': 0,
          'summary': {
            'brick': false,
            'description': {
              'execution': '',
              'fueling': '',
              'general':
                  'During the recovery periods between intervals, reduce effort and allow heart rate to drop',
              'purpose': '',
              'tips': '',
              'video_url': '',
            },
            'form': false,
            'index_max': 7,
            'measurement_unit': 'second',
            'name': 'HPH Longevity - 10min tempo intervals cardio (L)',
            'private': false,
            'sport': 'WALKING',
            'tags': '',
            'test_workout': false,
            'zone_unit': 'HR',
          },
          'tiz': [960, 1200, 1200, 0, 0, 0, 0],
          'training_load': 40,
          'workout_chart': [
            {
              'duration': 1200,
              'intensity': 65,
              'sport': 'WALKING',
              'value': 142.5,
            },
            {
              'duration': 600,
              'intensity': 75,
              'sport': 'WALKING',
              'value': 154.0,
            },
            {
              'duration': 180,
              'intensity': 54,
              'sport': 'WALKING',
              'value': 123.5,
            },
            {
              'duration': 600,
              'intensity': 75,
              'sport': 'WALKING',
              'value': 154.0,
            },
            {
              'duration': 180,
              'intensity': 54,
              'sport': 'WALKING',
              'value': 123.5,
            },
            {
              'duration': 600,
              'intensity': 54,
              'sport': 'WALKING',
              'value': 123.5,
            },
          ],
          'workout_id': 902127,
          'zone_target': 'TEMPO',
        },
      ],
    ),
    _Scenario(
      label: 'Swimming — Beach Race Starts OW',
      icon: Icons.waves,
      color: Colors.cyan.shade800,
      workouts: [
        {
          'schedule_id': 'swim-beach-race-starts-001',
          'sport': 'SWIMMING',
   "metric_type":"IMPERIAL",
"average_intensity":84,
"blocks":[
{
"block_intent":"WARMUP",
"cadence_min":0,
"distance":297,
"duration":480,
"equipment_type":"",
"id":2095099,
"intensity":72,
"measurement_unit":"second",
"sport":"SWIMMING",
"target_range":{
"high":1435,
"low":1794
},
"training_load":4,
"type":"WARMUP",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":0,
"duration":60,
"equipment_type":"",
"id":2095100,
"intensity":0,
"measurement_unit":"second",
"sport":"SWIMMING",
"target_range":{
"high":1160,
"low":1222
},
"training_load":0,
"type":"REST",
"zone_unit":"PACE"
},
{
"blocks":[
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":150,
"duration":190,
"equipment_type":"",
"id":2095103,
"intensity":90,
"measurement_unit":"yard",
"sport":"SWIMMING",
"target_range":{
"high":1222,
"low":1305
},
"training_load":3,
"type":"INTERVAL",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":0,
"duration":5,
"equipment_type":"",
"id":2095104,
"intensity":0,
"measurement_unit":"second",
"sport":"SWIMMING",
"target_range":{
"high":1160,
"low":1222
},
"training_load":0,
"type":"REST",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":150,
"duration":179,
"equipment_type":"",
"id":2095105,
"intensity":96,
"measurement_unit":"yard",
"sport":"SWIMMING",
"target_range":{
"high":1160,
"low":1222
},
"training_load":4,
"type":"INTERVAL",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":0,
"duration":60,
"equipment_type":"",
"id":2095106,
"intensity":0,
"measurement_unit":"second",
"sport":"SWIMMING",
"target_range":{
"high":1160,
"low":1222
},
"training_load":0,
"type":"REST",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":150,
"duration":190,
"equipment_type":"",
"id":2095107,
"intensity":90,
"measurement_unit":"yard",
"sport":"SWIMMING",
"target_range":{
"high":1222,
"low":1305
},
"training_load":3,
"type":"INTERVAL",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":0,
"duration":5,
"equipment_type":"",
"id":2095108,
"intensity":0,
"measurement_unit":"second",
"sport":"SWIMMING",
"target_range":{
"high":1160,
"low":1222
},
"training_load":0,
"type":"REST",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":150,
"duration":179,
"equipment_type":"",
"id":2095109,
"intensity":96,
"measurement_unit":"yard",
"sport":"SWIMMING",
"target_range":{
"high":1160,
"low":1222
},
"training_load":4,
"type":"INTERVAL",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":0,
"duration":60,
"equipment_type":"",
"id":2095110,
"intensity":0,
"measurement_unit":"second",
"sport":"SWIMMING",
"target_range":{
"high":1160,
"low":1222
},
"training_load":0,
"type":"REST",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":150,
"duration":190,
"equipment_type":"",
"id":2095111,
"intensity":90,
"measurement_unit":"yard",
"sport":"SWIMMING",
"target_range":{
"high":1222,
"low":1305
},
"training_load":3,
"type":"INTERVAL",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":0,
"duration":5,
"equipment_type":"",
"id":2095112,
"intensity":0,
"measurement_unit":"second",
"sport":"SWIMMING",
"target_range":{
"high":1160,
"low":1222
},
"training_load":0,
"type":"REST",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":150,
"duration":179,
"equipment_type":"",
"id":2095113,
"intensity":96,
"measurement_unit":"yard",
"sport":"SWIMMING",
"target_range":{
"high":1160,
"low":1222
},
"training_load":4,
"type":"INTERVAL",
"zone_unit":"PACE"
},
{
"block_intent":"MAINSET",
"cadence_min":0,
"distance":0,
"duration":60,
"equipment_type":"",
"id":2095114,
"intensity":0,
"measurement_unit":"second",
"sport":"SWIMMING",
"target_range":{
"high":1160,
"low":1222
},
"training_load":0,
"type":"REST",
"zone_unit":"PACE"
}
],
"distance":1800,
"duration":2604,
"repeat":2,
"training_load":49,
"type":"REPEAT"
},
{
"block_intent":"COOLDOWN",
"cadence_min":0,
"distance":223,
"duration":360,
"equipment_type":"",
"id":2095102,
"intensity":72,
"measurement_unit":"second",
"sport":"SWIMMING",
"target_range":{
"high":1435,
"low":1794
},
"training_load":3,
"type":"COOLDOWN",
"zone_unit":"PACE"
}
],
"brick_summaries":[
],
"distance":2320,
"duration":3504,
"id":28962,
"index":1,
"intent":"INTENSITY",
"interval_target":false,
"main_duration":2664,
"main_tiz":[
0,
0,
1140,
1074,
0,
0,
0
],
"priority":0,
"sport":"SWIMMING",
"summary":{
"brick":false,
   "indoor_outdoor": "INDOOR",
"description":{
"execution":"",
"fueling":"",
"general":"Practice your strong beach race finishes and your sighting strategy with 3 x (1 x 150 at Z3, turn around, 1x 150 at Z4 and a quick run up to the beach, then recover while wading back in the water). ",
"purpose":"",
"tips":"",
"video_url":""
},
"form":false,
"index_max":4,
"measurement_unit":"yard",
"name":"Beach race finishes and sighting open water-2",
"metric_type":"IMPERIAL",
"private":false,
"sport":"SWIMMING",
"tags":"sprints,speed,midd,sprintd,form",
"test_workout":false,
"zone_unit":"HR"
},

"tiz":[
840,
0,
1140,
1074,
0,
0,
0
],
"training_load":49,
"workout_chart":[
{
"duration":480,
"intensity":72,
"sport":"SWIMMING",
"value":1614.5
},
{
"duration":60,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":190,
"intensity":90,
"sport":"SWIMMING",
"value":1263.5
},
{
"duration":5,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":179,
"intensity":96,
"sport":"SWIMMING",
"value":1191
},
{
"duration":60,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":190,
"intensity":90,
"sport":"SWIMMING",
"value":1263.5
},
{
"duration":5,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":179,
"intensity":96,
"sport":"SWIMMING",
"value":1191
},
{
"duration":60,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":190,
"intensity":90,
"sport":"SWIMMING",
"value":1263.5
},
{
"duration":5,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":179,
"intensity":96,
"sport":"SWIMMING",
"value":1191
},
{
"duration":60,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":190,
"intensity":90,
"sport":"SWIMMING",
"value":1263.5
},
{
"duration":5,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":179,
"intensity":96,
"sport":"SWIMMING",
"value":1191
},
{
"duration":60,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":190,
"intensity":90,
"sport":"SWIMMING",
"value":1263.5
},
{
"duration":5,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":179,
"intensity":96,
"sport":"SWIMMING",
"value":1191
},
{
"duration":60,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":190,
"intensity":90,
"sport":"SWIMMING",
"value":1263.5
},
{
"duration":5,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":179,
"intensity":96,
"sport":"SWIMMING",
"value":1191
},
{
"duration":60,
"intensity":0,
"sport":"SWIMMING",
"value":1191
},
{
"duration":360,
"intensity":72,
"sport":"SWIMMING",
"value":1614.5
}
],
"workout_id":677287,
"zone_target":"THRESHOLD"

        },
     
      ],
    ),
    _Scenario(
      label: 'Running — Ultra Long Endurance (Imperial)',
      icon: Icons.directions_run,
      color: Colors.red.shade800,
      workouts: [
        {
          "schedule_id": "ultra-endurance-imperial-001",
          "date": "2026-05-19T08:00:00Z",
          "sport": "RUNNING",
          "metric_type": "IMPERIAL",
          "average_intensity": 51,
          "blocks": [
            {
              "block_intent": "WARMUP",
              "cadence_min": 0,
              "description": "Aim to reach Z2 by the end of your warm up",
              "distance": 555,
              "duration": 600,
              "equipment_type": "",
              "id": 2090346,
              "intensity": 42,
              "measurement_unit": "second",
              "sport": "RUNNING",
              "target_range": {"high": 140, "low": 122},
              "training_load": 2,
              "type": "WARMUP",
              "zone_unit": "HR"
            },
            {
              "block_intent": "MAINSET",
              "cadence_min": 0,
              "distance": 33789,
              "duration": 29667,
              "equipment_type": "",
              "id": 2090347,
              "intensity": 51,
              "measurement_unit": "meter",
              "sport": "RUNNING",
              "target_range": {"high": 146, "low": 134},
              "training_load": 214,
              "type": "INTERVAL",
              "zone_unit": "HR"
            },
            {
              "block_intent": "COOLDOWN",
              "cadence_min": 0,
              "description": "Gradually lower heart rate to Z1 by the end of your warm down",
              "distance": 555,
              "duration": 600,
              "equipment_type": "",
              "id": 2090348,
              "intensity": 42,
              "measurement_unit": "second",
              "sport": "RUNNING",
              "target_range": {"high": 134, "low": 107},
              "training_load": 2,
              "type": "COOLDOWN",
              "zone_unit": "HR"
            }
          ],
          "distance": 34899,
          "duration": 30867,
          "id": 12644,
          "index": 2,
          "intent": "ENDURANCE",
          "summary": {
            "brick": false,
            "description": {
              "execution": "",
              "fueling": "",
              "general": "This session will improve your body's ability to endure hours of sustained activity with a more efficient metabolism.",
              "purpose": "",
              "tips": ""
            },
            "elevation": "HILLS",
            "form": false,
            "index_max": 8,
            "measurement_unit": "meter",
            "name": "Ultra long endurance-3 (Imperial)",
            "sport": "RUNNING",
            "tags": "ultra, ultra-xl",
            "test_workout": false,
            "zone_unit": "PACE",
            "indoor_outdoor": "OUTDOOR"
          },
          "training_load": 220,
          "workout_id": 25408,
          "zone_target": "ENDURANCE"
        },
      ],
    ),
    _Scenario(
      label: 'Running — Ultra Long Endurance (Metric)',
      icon: Icons.directions_run,
      color: Colors.green.shade800,
      workouts: [
        {
          "schedule_id": "ultra-endurance-metric-001",
          "date": "2026-05-19T08:00:00Z",
          "sport": "RUNNING",
          "metric_type": "METRIC",
          "average_intensity": 51,
          "blocks": [
            {
              "block_intent": "WARMUP",
              "cadence_min": 0,
              "description": "Aim to reach Z2 by the end of your warm up",
              "distance": 555,
              "duration": 600,
              "equipment_type": "",
              "id": 2090346,
              "intensity": 42,
              "measurement_unit": "second",
              "sport": "RUNNING",
              "target_range": {"high": 140, "low": 122},
              "training_load": 2,
              "type": "WARMUP",
              "zone_unit": "HR"
            },
            {
              "block_intent": "MAINSET",
              "cadence_min": 0,
              "distance": 33789,
              "duration": 29667,
              "equipment_type": "",
              "id": 2090347,
              "intensity": 51,
              "measurement_unit": "meter",
              "sport": "RUNNING",
              "target_range": {"high": 146, "low": 134},
              "training_load": 214,
              "type": "INTERVAL",
              "zone_unit": "HR"
            },
            {
              "block_intent": "COOLDOWN",
              "cadence_min": 0,
              "description": "Gradually lower heart rate to Z1 by the end of your warm down",
              "distance": 555,
              "duration": 600,
              "equipment_type": "",
              "id": 2090348,
              "intensity": 42,
              "measurement_unit": "second",
              "sport": "RUNNING",
              "target_range": {"high": 134, "low": 107},
              "training_load": 2,
              "type": "COOLDOWN",
              "zone_unit": "HR"
            }
          ],
          "distance": 34899,
          "duration": 30867,
          "id": 12644,
          "index": 2,
          "intent": "ENDURANCE",
          "summary": {
            "brick": false,
            "description": {
              "execution": "",
              "fueling": "",
              "general": "This session will improve your body's ability to endure hours of sustained activity with a more efficient metabolism.",
              "purpose": "",
              "tips": ""
            },
            "elevation": "HILLS",
            "form": false,
            "index_max": 8,
            "measurement_unit": "meter",
            "name": "Ultra long endurance-3 (Metric)",
            "sport": "RUNNING",
            "tags": "ultra, ultra-xl",
            "test_workout": false,
            "zone_unit": "PACE",
            "indoor_outdoor": "OUTDOOR"
          },
          "training_load": 220,
          "workout_id": 25408,
          "zone_target": "ENDURANCE"
        },
      ],
    ),
    _Scenario(
      label: 'Running — Ultra Endurance (Power Alert)',
      icon: Icons.directions_run,
      color: Colors.purple.shade800,
      workouts: [
        {
          "schedule_id": "ultra-endurance-power-001",
          "date": "2026-05-19T08:00:00Z",
          "sport": "RUNNING",
          "metric_type": "METRIC",
          "average_intensity": 51,
          "blocks": [
            {
              "block_intent": "WARMUP",
              "cadence_min": 0,
              "description": "Aim to reach Z2 by the end of your warm up",
              "distance": 555,
              "duration": 600,
              "equipment_type": "",
              "id": 2090346,
              "intensity": 49,
              "measurement_unit": "second",
              "sport": "RUNNING",
              "target_range": {"high": 79, "low": 64},
              "training_load": 4,
              "type": "WARMUP",
              "zone_unit": "POWER"
            },
            {
              "block_intent": "MAINSET",
              "cadence_min": 0,
              "distance": 33789,
              "duration": 29667,
              "equipment_type": "",
              "id": 2090347,
              "intensity": 51,
              "measurement_unit": "meter",
              "sport": "RUNNING",
              "target_range": {"high": 91, "low": 64},
              "training_load": 214,
              "type": "INTERVAL",
              "zone_unit": "POWER"
            },
            {
              "block_intent": "COOLDOWN",
              "cadence_min": 0,
              "description": "Gradually lower heart rate to Z1 by the end of your warm down",
              "distance": 555,
              "duration": 600,
              "equipment_type": "",
              "id": 2090348,
              "intensity": 38,
              "measurement_unit": "second",
              "sport": "RUNNING",
              "target_range": {"high": 64, "low": 51},
              "training_load": 2,
              "type": "COOLDOWN",
              "zone_unit": "POWER"
            }
          ],
          "distance": 34899,
          "duration": 30867,
          "id": 12644,
          "index": 2,
          "intent": "ENDURANCE",
          "summary": {
            "brick": false,
            "description": {
              "execution": "",
              "fueling": "",
              "general": "This session will improve your body's ability to endure hours of sustained activity with a more efficient metabolism.",
              "purpose": "",
              "tips": ""
            },
            "elevation": "HILLS",
            "form": false,
            "index_max": 8,
            "measurement_unit": "meter",
            "name": "Ultra long endurance-3 (Power)",
            "sport": "RUNNING",
            "tags": "ultra, ultra-xl",
            "test_workout": false,
            "zone_unit": "POWER",
            "indoor_outdoor": "OUTDOOR"
          },
          "training_load": 220,
          "workout_id": 25408,
          "zone_target": "ENDURANCE"
        },
      ],
    ),
    _Scenario(
      label: 'Running — Ultra Endurance (Pace Alert)',
      icon: Icons.directions_run,
      color: Colors.indigo.shade800,
      workouts: [
        {
          "schedule_id": "ultra-endurance-pace-001",
          "date": "2026-05-19T08:00:00Z",
          "sport": "RUNNING",
          "metric_type": "METRIC",
          "average_intensity": 51,
          "blocks": [
            {
              "block_intent": "WARMUP",
              "cadence_min": 0,
              "description": "Aim to reach Z2 by the end of your warm up",
              "distance": 555,
              "duration": 600,
              "equipment_type": "",
              "id": 2090346,
              "intensity": 49,
              "measurement_unit": "second",
              "sport": "RUNNING",
              "target_range": {"high": 878, "low": 1082},
              "training_load": 4,
              "type": "WARMUP",
              "zone_unit": "PACE"
            },
            {
              "block_intent": "MAINSET",
              "cadence_min": 0,
              "distance": 33789,
              "duration": 29667,
              "equipment_type": "",
              "id": 2090347,
              "intensity": 51,
              "measurement_unit": "meter",
              "sport": "RUNNING",
              "target_range": {"high": 757, "low": 1082},
              "training_load": 214,
              "type": "INTERVAL",
              "zone_unit": "PACE"
            },
            {
              "block_intent": "COOLDOWN",
              "cadence_min": 0,
              "description": "Gradually lower heart rate to Z1 by the end of your warm down",
              "distance": 555,
              "duration": 600,
              "equipment_type": "",
              "id": 2090348,
              "intensity": 42,
              "measurement_unit": "second",
              "sport": "RUNNING",
              "target_range": {"high": 1082, "low": 1352},
              "training_load": 2,
              "type": "COOLDOWN",
              "zone_unit": "PACE"
            }
          ],
          "distance": 34899,
          "duration": 30867,
          "id": 12644,
          "index": 2,
          "intent": "ENDURANCE",
          "summary": {
            "brick": false,
            "description": {
              "execution": "",
              "fueling": "",
              "general": "This session will improve your body's ability to endure hours of sustained activity with a more efficient metabolism.",
              "purpose": "",
              "tips": ""
            },
            "elevation": "HILLS",
            "form": false,
            "index_max": 8,
            "measurement_unit": "meter",
            "name": "Ultra long endurance-3 (Pace)",
            "sport": "RUNNING",
            "tags": "ultra, ultra-xl",
            "test_workout": false,
            "zone_unit": "PACE",
            "indoor_outdoor": "OUTDOOR"
          },
          "training_load": 221,
          "workout_id": 25408,
          "zone_target": "ENDURANCE"
        },
      ],
    ),
    _Scenario(
      label: 'Swimming — 200s Block Pool (Metric)',
      icon: Icons.pool,
      color: Colors.blue.shade900,
      workouts: [
        {
          "schedule_id": "swim-200s-block-metric-001",
          "date": "2026-05-19T08:00:00Z",
          "sport": "SWIMMING",
          "metric_type": "METRIC",
          "average_intensity": 84,
          "blocks": [
            {
              "blocks": [
                {"block_intent": "MAINSET", "cadence_min": 0, "description": "Drill - 3/4 catch up", "distance": 100, "duration": 179, "equipment_type": "", "id": 2093880, "intensity": 83, "measurement_unit": "meter", "sport": "SWIMMING", "stroke_type": "DRILL", "target_range": {"high": 1705, "low": 1875}, "training_load": 2, "type": "WARMUP", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 30, "equipment_type": "", "id": 2093881, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"}
              ],
              "distance": 200,
              "duration": 418,
              "repeat": 2,
              "training_load": 5,
              "type": "REPEAT"
            },
            {
              "blocks": [
                {"block_intent": "MAINSET", "cadence_min": 0, "description": "Kick with board and fins", "distance": 25, "duration": 45, "equipment_type": "SWIM_KICKBOARD,SWIM_FINS", "id": 2093882, "intensity": 83, "measurement_unit": "meter", "sport": "SWIMMING", "stroke_type": "DRILL", "target_range": {"high": 1705, "low": 1875}, "training_load": 0, "type": "WARMUP", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 30, "equipment_type": "", "id": 2093883, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"}
              ],
              "distance": 100,
              "duration": 300,
              "repeat": 4,
              "training_load": 2,
              "type": "REPEAT"
            },
            {
              "blocks": [
                {"block_intent": "MAINSET", "cadence_min": 0, "description": "Build Z2 to Z6 by the end of each 50", "distance": 50, "duration": 72, "equipment_type": "", "id": 2093884, "intensity": 103, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1429, "low": 1456}, "training_load": 2, "type": "WARMUP", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 45, "equipment_type": "", "id": 2093885, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"}
              ],
              "distance": 200,
              "duration": 468,
              "repeat": 4,
              "training_load": 8,
              "type": "REPEAT"
            },
            {
              "blocks": [
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 200, "duration": 330, "equipment_type": "", "id": 2093886, "intensity": 90, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1596, "low": 1705}, "training_load": 6, "type": "INTERVAL", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 20, "equipment_type": "", "id": 2093887, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"}
              ],
              "distance": 1000,
              "duration": 1750,
              "repeat": 5,
              "training_load": 33,
              "type": "REPEAT"
            },
            {
              "block_intent": "COOLDOWN",
              "cadence_min": 0,
              "description": "Gradually lower heart rate to Z1 by the end of your warm down",
              "distance": 200,
              "duration": 422,
              "equipment_type": "",
              "id": 2093879,
              "intensity": 72,
              "measurement_unit": "meter",
              "sport": "SWIMMING",
              "target_range": {"high": 1875, "low": 2344},
              "training_load": 4,
              "type": "COOLDOWN",
              "zone_unit": "PACE"
            }
          ],
          "distance": 1700,
          "duration": 3358,
          "id": 13012,
          "index": 0,
          "intent": "INTERVALS",
          "summary": {
            "brick": false,
            "description": {
              "execution": "",
              "fueling": "",
              "general": "After some high intensity (but short) efforts in your warm up settle into some 200 tempo intervals.",
              "purpose": "",
              "tips": ""
            },
            "form": false,
            "index_max": 2,
            "measurement_unit": "meter",
            "name": "200's block (Metric)",
            "pool_size": "25m",
            "sport": "SWIMMING",
            "tags": "novice, endurance",
            "test_workout": false,
            "zone_unit": "PACE",
            "indoor_outdoor": "INDOOR"
          },
          "training_load": 40,
          "workout_id": 26994,
          "zone_target": "TEMPO"
        },
      ],
    ),
    _Scenario(
      label: 'Swimming — Beach Race Pool (IMPERIAL/meters)',
      icon: Icons.pool,
      color: Colors.teal.shade900,
      workouts: [
        {
          "schedule_id": "beach-race-metric-meters-001",
          "date": "2026-05-19T08:00:00Z",
          "sport": "SWIMMING",
          "metric_type": "IMPERIAL",
          "average_intensity": 86,
          "blocks": [
            {
              "block_intent": "WARMUP",
              "cadence_min": 0,
              "distance": 227,
              "duration": 480,
              "equipment_type": "",
              "id": 2095099,
              "intensity": 72,
              "measurement_unit": "second",
              "sport": "SWIMMING",
              "target_range": {"high": 1875, "low": 2344},
              "training_load": 4,
              "type": "WARMUP",
              "zone_unit": "PACE"
            },
            {
              "block_intent": "MAINSET",
              "cadence_min": 0,
              "distance": 0,
              "duration": 60,
              "equipment_type": "",
              "id": 2095100,
              "intensity": 0,
              "measurement_unit": "second",
              "sport": "SWIMMING",
              "target_range": {"high": 1515, "low": 1596},
              "training_load": 0,
              "type": "REST",
              "zone_unit": "PACE"
            },
            {
              "blocks": [
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 248, "equipment_type": "", "id": 2095103, "intensity": 90, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1596, "low": 1705}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 5, "equipment_type": "", "id": 2095104, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 233, "equipment_type": "", "id": 2095105, "intensity": 96, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 60, "equipment_type": "", "id": 2095106, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 248, "equipment_type": "", "id": 2095107, "intensity": 90, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1596, "low": 1705}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 5, "equipment_type": "", "id": 2095108, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 233, "equipment_type": "", "id": 2095109, "intensity": 96, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 60, "equipment_type": "", "id": 2095110, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 248, "equipment_type": "", "id": 2095111, "intensity": 90, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1596, "low": 1705}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 5, "equipment_type": "", "id": 2095112, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 233, "equipment_type": "", "id": 2095113, "intensity": 96, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
                {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 60, "equipment_type": "", "id": 2095114, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"}
              ],
              "distance": 1800,
              "duration": 3276,
              "repeat": 2,
              "training_load": 64,
              "type": "REPEAT"
            },
            {
              "block_intent": "COOLDOWN",
              "cadence_min": 0,
              "distance": 171,
              "duration": 360,
              "equipment_type": "",
              "id": 2095102,
              "intensity": 72,
              "measurement_unit": "second",
              "sport": "SWIMMING",
              "target_range": {"high": 1875, "low": 2344},
              "training_load": 3,
              "type": "COOLDOWN",
              "zone_unit": "PACE"
            }
          ],
          "distance": 2198,
          "duration": 4176,
          "id": 28962,
          "index": 1,
          "intent": "INTENSITY",
          "summary": {
            "brick": false,
            "description": {
              "execution": "",
              "fueling": "",
              "general": "Practice your strong beach race finishes and your sighting strategy with 3 x (1 x 150 at Z3, turn around, 1x 150 at Z4 and a quick run up to the beach, then recover while wading back in the water).",
              "purpose": "",
              "tips": ""
            },
            "form": false,
            "index_max": 4,
            "measurement_unit": "meter",
            "name": "Beach race finishes and sighting open water-2 (Metric)",
            "pool_size": "25m",
            "sport": "SWIMMING",
            "tags": "sprints,speed,midd,sprintd,form",
            "test_workout": false,
            "zone_unit": "PACE",
            "indoor_outdoor": "INDOOR"
          },
          "training_load": 62,
          "workout_id": 677287,
          "zone_target": "THRESHOLD"
        },
      ],
    ),
 
    // _Scenario(
    //   label: 'Swimming — Beach Race Pool (Metric/meters)',
    //   icon: Icons.pool,
    //   color: Colors.teal.shade900,
    //   workouts: [
    //     {
    //       "schedule_id": "beach-race-metric-meters-001",
    //       "date": "2026-05-19T08:00:00Z",
    //       "sport": "SWIMMING",
    //       "metric_type": "METRIC",
    //       "average_intensity": 86,
    //       "blocks": [
    //         {
    //           "block_intent": "WARMUP",
    //           "cadence_min": 0,
    //           "distance": 227,
    //           "duration": 480,
    //           "equipment_type": "",
    //           "id": 2095099,
    //           "intensity": 72,
    //           "measurement_unit": "second",
    //           "sport": "SWIMMING",
    //           "target_range": {"high": 1875, "low": 2344},
    //           "training_load": 4,
    //           "type": "WARMUP",
    //           "zone_unit": "PACE"
    //         },
    //         {
    //           "block_intent": "MAINSET",
    //           "cadence_min": 0,
    //           "distance": 0,
    //           "duration": 60,
    //           "equipment_type": "",
    //           "id": 2095100,
    //           "intensity": 0,
    //           "measurement_unit": "second",
    //           "sport": "SWIMMING",
    //           "target_range": {"high": 1515, "low": 1596},
    //           "training_load": 0,
    //           "type": "REST",
    //           "zone_unit": "PACE"
    //         },
    //         {
    //           "blocks": [
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 248, "equipment_type": "", "id": 2095103, "intensity": 90, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1596, "low": 1705}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 5, "equipment_type": "", "id": 2095104, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"},
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 233, "equipment_type": "", "id": 2095105, "intensity": 96, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 60, "equipment_type": "", "id": 2095106, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"},
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 248, "equipment_type": "", "id": 2095107, "intensity": 90, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1596, "low": 1705}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 5, "equipment_type": "", "id": 2095108, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"},
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 233, "equipment_type": "", "id": 2095109, "intensity": 96, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 60, "equipment_type": "", "id": 2095110, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"},
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 248, "equipment_type": "", "id": 2095111, "intensity": 90, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1596, "low": 1705}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 5, "equipment_type": "", "id": 2095112, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"},
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 150, "duration": 233, "equipment_type": "", "id": 2095113, "intensity": 96, "measurement_unit": "meter", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 5, "type": "INTERVAL", "zone_unit": "PACE"},
    //             {"block_intent": "MAINSET", "cadence_min": 0, "distance": 0, "duration": 60, "equipment_type": "", "id": 2095114, "intensity": 0, "measurement_unit": "second", "sport": "SWIMMING", "target_range": {"high": 1515, "low": 1596}, "training_load": 0, "type": "REST", "zone_unit": "PACE"}
    //           ],
    //           "distance": 1800,
    //           "duration": 3276,
    //           "repeat": 2,
    //           "training_load": 64,
    //           "type": "REPEAT"
    //         },
    //         {
    //           "block_intent": "COOLDOWN",
    //           "cadence_min": 0,
    //           "distance": 171,
    //           "duration": 360,
    //           "equipment_type": "",
    //           "id": 2095102,
    //           "intensity": 72,
    //           "measurement_unit": "second",
    //           "sport": "SWIMMING",
    //           "target_range": {"high": 1875, "low": 2344},
    //           "training_load": 3,
    //           "type": "COOLDOWN",
    //           "zone_unit": "PACE"
    //         }
    //       ],
    //       "distance": 2198,
    //       "duration": 4176,
    //       "id": 28962,
    //       "index": 1,
    //       "intent": "INTENSITY",
    //       "summary": {
    //         "brick": false,
    //         "description": {
    //           "execution": "",
    //           "fueling": "",
    //           "general": "Practice your strong beach race finishes and your sighting strategy with 3 x (1 x 150 at Z3, turn around, 1x 150 at Z4 and a quick run up to the beach, then recover while wading back in the water).",
    //           "purpose": "",
    //           "tips": ""
    //         },
    //         "form": false,
    //         "index_max": 4,
    //         "measurement_unit": "meter",
    //         "name": "Beach race finishes and sighting open water-2 (Metric)",
    //         "pool_size": "25m",
    //         "sport": "SWIMMING",
    //         "tags": "sprints,speed,midd,sprintd,form",
    //         "test_workout": false,
    //         "zone_unit": "PACE",
    //         "indoor_outdoor": "INDOOR"
    //       },
    //       "training_load": 62,
    //       "workout_id": 677287,
    //       "zone_target": "THRESHOLD"
    //     },
    //   ],
    // ),
 
  ];

  // ── Date-format test scenario ──────────────────────────────────────────────

  /// Builds a scenario that schedules four identical workouts differing only
  /// in the format of the 'date' string — verifying that the Swift layer
  /// accepts all supported ISO-8601 variants.
  _Scenario get _dateFormatScenario {
    final tomorrow = DateTime.now().toUtc().add(const Duration(days: 1));
    final y = tomorrow.year.toString().padLeft(4, '0');
    final m = tomorrow.month.toString().padLeft(2, '0');
    final d = tomorrow.day.toString().padLeft(2, '0');
    final base = '$y-$m-${d}T';

    Map<String, dynamic> _workout(String id, String date, String label) => {
      'schedule_id': id,
      'sport': 'RUNNING',
      'date': date,
      'summary': {
        'name': label,
        'sport': 'RUNNING',
        'measurement_unit': 'second',
      },
      'blocks': [
        {
          'type': 'INTERVAL',
          'duration': 1800,
          'distance': 5000.0,
          'measurement_unit': 'second',
          'sport': 'RUNNING',
          'zone_unit': 'PACE',
          'target_range': {'low': 360, 'high': 300},
        },
      ],
    };

    return _Scenario(
      label: 'Date Format Test (4 variants)',
      icon: Icons.date_range,
      color: Colors.deepPurple,
      preserveDates: true,
      workouts: [
        // Format 1: ISO-8601 with Z, no fractional seconds
        _workout('date-fmt-z-001', '${base}08:00:00Z', 'Fmt1: ...T08:00:00Z'),
        // Format 2: no timezone suffix (treated as UTC by DateUtils)
        _workout('date-fmt-no-tz-001', '${base}09:00:00', 'Fmt2: ...T09:00:00'),
        // Format 3: milliseconds + Z
        _workout(
          'date-fmt-ms-z-001',
          '${base}10:00:00.000Z',
          'Fmt3: ...T10:00:00.000Z',
        ),
        // Format 4: microseconds, no timezone
        _workout(
          'date-fmt-micro-no-tz-001',
          '${base}11:00:00.000000',
          'Fmt4: ...T11:00:00.000000',
        ),
      ],
    );
  }

  // ── Core push logic ───────────────────────────────────────────────────────

  /// Injects a valid forward-looking date into every workout map and pushes.
  /// When [preserveDates] is true the 'date' field already present in each
  /// workout map is kept unchanged (used by the date-format test scenario).
  Future<void> _pushWorkouts(
    List<Map<String, dynamic>> workouts,
    String scenarioLabel, {
    bool preserveDates = false,
    Duration dateOffset = const Duration(hours: 2),
  }) async {
    setState(() {
      _isPushing = true;
      _lastResponse = null;
      _errorMessage = null;
      _activeScenarioLabel = scenarioLabel;
    });

    try {
      // Deep-copy so the original scenario maps are not mutated
      final List<Map<String, dynamic>> mutable = workouts
          .map((w) => Map<String, dynamic>.from(w))
          .toList();

      // Apple WorkoutKit requires dates strictly between now and +7 days.
      // When preserveDates is true the caller has already embedded valid dates
      // in each workout (e.g. the date-format test scenario).
      if (!preserveDates) {
        for (final map in mutable) {
          final forward = DateTime.now().add(dateOffset).toUtc();
          map['date'] = '${forward.toIso8601String().substring(0, 19)}Z';
        }
      }

      final List<WorkoutPushEntry> entries = mutable.map((m) {
        return WorkoutPushEntry(
          scheduleId: m['schedule_id']?.toString() ?? '',
          sport:
              AppleSportExtension.fromJsonValue(m['sport'] as String? ?? '') ??
              AppleSport.running,
          metricType:
              MetricTypeExtension.fromJsonValue(m['metric_type'] as String? ?? '') ??
              MetricType.unspecified,
          data: m,
        );
      }).toList();

      final response = await _pushManager.pushRawWorkouts(entries);

      setState(() {
        _lastResponse = response;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      setState(() {
        _isPushing = false;
      });
    }
  }

  /// Parses pasted JSON and pushes it.
  Future<void> _pushPastedJson() async {
    final raw = _jsonController.text.trim();
    if (raw.isEmpty) {
      setState(() => _errorMessage = 'Paste field is empty.');
      return;
    }

    late final List<Map<String, dynamic>> workouts;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        workouts = decoded
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } else if (decoded is Map) {
        workouts = [Map<String, dynamic>.from(decoded)];
      } else {
        setState(() => _errorMessage = 'JSON must be an object or array.');
        return;
      }
    } catch (e) {
      setState(() => _errorMessage = 'Invalid JSON: $e');
      return;
    }

    await _pushWorkouts(workouts, 'Pasted JSON');
  }

  Future<void> _clearCache() async {
    setState(() {
      _isPushing = true;
      _lastResponse = null;
      _errorMessage = null;
      _activeScenarioLabel = 'Clearing…';
    });

    try {
      final response = await _pushManager.removeAllScheduledWorkouts();
      final removedFromWatch = response['removedFromWatch'] as int? ?? 0;
      final localCleared = response['localRecordsCleared'] as int? ?? 0;
      final error = response['error'] as String?;

      setState(() {
        _errorMessage = error != null
            ? 'Clear failed: $error'
            : 'Removed $removedFromWatch workout(s) from Apple Watch, '
                  '$localCleared local record(s) cleared.\n'
                  'Push a fresh scenario to test with the latest native code.';
        _activeScenarioLabel = null;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Clear failed: $e';
        _activeScenarioLabel = null;
      });
    } finally {
      setState(() => _isPushing = false);
    }
  }

  // ── Manage Scheduled Workouts ─────────────────────────────────────────────

  Future<void> _loadScheduledWorkouts() async {
    setState(() {
      _isLoadingScheduled = true;
      _manageMessage = null;
    });
    try {
      final list = await _pushManager.getScheduledWorkouts();
      setState(() {
        _scheduledWorkouts = list;
        _manageMessage = list.isEmpty
            ? 'No workouts currently scheduled on Apple Watch.'
            : null;
      });
    } catch (e) {
      setState(() => _manageMessage = 'Load failed: $e');
    } finally {
      setState(() => _isLoadingScheduled = false);
    }
  }

  Future<void> _removeAllWorkouts() async {
    setState(() {
      _isLoadingScheduled = true;
      _manageMessage = null;
    });
    try {
      final response = await _pushManager.removeAllScheduledWorkouts();
      final removed = response['removedFromWatch'] as int? ?? 0;
      final local = response['localRecordsCleared'] as int? ?? 0;
      final error = response['error'] as String?;
      setState(() {
        _scheduledWorkouts = [];
        _manageMessage = error != null
            ? '❌ Remove all failed: $error'
            : '✅ Removed $removed from Apple Watch, $local local records cleared.';
      });
    } catch (e) {
      setState(() => _manageMessage = '❌ Remove all failed: $e');
    } finally {
      setState(() => _isLoadingScheduled = false);
    }
  }

  Future<void> _removeWorkoutById(String workoutPlanId) async {
    setState(() => _removingIds.add(workoutPlanId));
    try {
      final results = await _pushManager.removeScheduledWorkouts([
        workoutPlanId,
      ]);
      if (results.isEmpty) {
        setState(() => _manageMessage = '❌ No response for $workoutPlanId');
        return;
      }
      final r = results.first;
      switch (r.status) {
        case WorkoutRemovalStatus.success:
          setState(() {
            _scheduledWorkouts.removeWhere((w) => w.id == workoutPlanId);
            _manageMessage =
                '✅ Removed ${r.scheduleId ?? workoutPlanId} from Apple Watch and local storage.';
          });
          break;
        case WorkoutRemovalStatus.partial:
          setState(() {
            _scheduledWorkouts.removeWhere((w) => w.id == workoutPlanId);
            _manageMessage = '⚠️ Partial: ${r.message}';
          });
          break;
        case WorkoutRemovalStatus.fail:
          setState(
            () => _manageMessage =
                '❌ Not found: ${r.workoutPlanId}\n${r.message}',
          );
          break;
      }
    } catch (e) {
      setState(() => _manageMessage = '❌ Remove failed: $e');
    } finally {
      setState(() => _removingIds.remove(workoutPlanId));
    }
  }

  Widget _buildManageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Manage Scheduled Workouts',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          'Lists workouts currently scheduled on Apple Watch. '
          'Remove individually or all at once.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isLoadingScheduled ? null : _loadScheduledWorkouts,
                icon: _isLoadingScheduled
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh List'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isLoadingScheduled || _scheduledWorkouts.isEmpty
                    ? null
                    : _removeAllWorkouts,
                icon: const Icon(Icons.delete_sweep, size: 18),
                label: const Text('Remove All'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
              ),
            ),
          ],
        ),
        if (_manageMessage != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Text(_manageMessage!, style: const TextStyle(fontSize: 12)),
          ),
        ],
        if (_scheduledWorkouts.isNotEmpty) ...[
          const SizedBox(height: 8),
          ..._scheduledWorkouts.map((w) {
            final removing = _removingIds.contains(w.id);
            return Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                dense: true,
                title: Text(
                  w.name ?? w.activityType ?? 'Workout',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (w.scheduleId != null)
                      Text(
                        'schedule_id: ${w.scheduleId}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    if (w.sport != null)
                      Text(
                        'sport: ${w.sport!.jsonValue}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.deepPurple,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    Text(
                      'planId: ${w.id}',
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                    if (w.scheduledDate != null)
                      Text(
                        'date: ${w.scheduledDate!.toLocal().toString().substring(0, 16)}',
                        style: const TextStyle(fontSize: 11),
                      ),
                  ],
                ),
                trailing: removing
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: const Icon(
                          Icons.delete,
                          color: Colors.red,
                          size: 20,
                        ),
                        tooltip: 'Remove this workout',
                        onPressed: () => _removeWorkoutById(w.id),
                      ),
              ),
            );
          }),
        ],
      ],
    );
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  Widget _buildScenarioButton(_Scenario s) {
    final bool isActive = _isPushing && _activeScenarioLabel == s.label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ElevatedButton.icon(
        onPressed: _isPushing
            ? null
            : () => _pushWorkouts(
                s.workouts,
                s.label,
                preserveDates: s.preserveDates,
                dateOffset: s.dateOffset,
              ),
        icon: isActive
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(s.icon, size: 18),
        label: Text(s.label),
        style: ElevatedButton.styleFrom(
          backgroundColor: s.color,
          foregroundColor: Colors.white,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        ),
      ),
    );
  }

  Widget _buildResultsPanel() {
    final response = _lastResponse;
    final error = _errorMessage;

    if (error != null && response == null) {
      return _infoBox(
        color: Colors.red.shade50,
        border: Colors.red.shade200,
        child: Text(
          '❌ $error',
          style: TextStyle(
            color: Colors.red.shade800,
            fontFamily: 'Courier',
            fontSize: 13,
          ),
        ),
      );
    }

    if (response == null) {
      return _infoBox(
        color: Colors.grey.shade100,
        border: Colors.grey.shade300,
        child: Text(
          'Results will appear here after pushing.',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
      );
    }

    final successCount = response.successful;
    final skippedCount = response.skipped;
    final failedCount = response.failed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Summary bar
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.grey.shade800,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _activeScenarioLabel ?? '',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _summaryChip('$successCount scheduled', Colors.green),
                  const SizedBox(width: 6),
                  _summaryChip('$skippedCount skipped', Colors.amber.shade700),
                  const SizedBox(width: 6),
                  _summaryChip('$failedCount failed', Colors.red),
                ],
              ),
            ],
          ),
        ),
        // Per-result tiles
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(8),
            ),
          ),
          child: response.results.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('No results returned.'),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: response.results.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: Colors.grey.shade200),
                  itemBuilder: (_, i) => _buildResultTile(response.results[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildResultTile(WorkoutPushResult r) {
    final (icon, color, title, subtitle) = switch (r.status) {
      WorkoutPushStatus.success => (
        Icons.check_circle,
        Colors.green,
        'Scheduled',
        'Plan ID: ${r.workoutPlanId ?? "—"}\nWorkout ID: ${r.workoutId}',
      ),
      WorkoutPushStatus.skipped => (
        Icons.skip_next,
        Colors.amber.shade700,
        'Skipped',
        r.skipReason ?? 'Already scheduled (no changes)',
      ),
      WorkoutPushStatus.validationError => (
        Icons.warning_amber,
        Colors.orange,
        'Validation Error',
        r.errorMessage ?? 'Unknown validation error',
      ),
      WorkoutPushStatus.failed => (
        Icons.error,
        Colors.red,
        'Failed',
        r.errorMessage ?? 'Unknown error',
      ),
    };

    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 22),
      title: Text(
        '$title  ·  ${r.scheduleId}',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontFamily: 'Courier', fontSize: 11),
      ),
    );
  }

  Widget _summaryChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _infoBox({
    required Color color,
    required Color border,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Push Workouts')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Section: Scenarios ───────────────────────────────────────
            const Text(
              'Test Scenarios',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Each button pushes a pre-built workout to Apple Watch via WorkoutKit. '
              'Re-pushing the same scenario will be deduped (skipped) unless the date '
              'changes content hash.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            ..._scenarios.map(_buildScenarioButton),

            const SizedBox(height: 24),
            const Divider(),

            // ── Section: Date Format Tests ───────────────────────────────
            const SizedBox(height: 8),
            const Text(
              'Date Format Tests',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Schedules 4 identical workouts for tomorrow, each using a different '
              'ISO-8601 date string format (with/without Z, with/without '
              'fractional seconds). All 4 should succeed to confirm the Swift '
              'DateUtils parser accepts every variant.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            _buildScenarioButton(_dateFormatScenario),

            const SizedBox(height: 24),
            const Divider(),

            // ── Section: Paste JSON ──────────────────────────────────────
            const SizedBox(height: 8),
            const Text(
              'Paste Custom JSON',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Paste a single workout object {} or an array [{}] of workouts. '
              'The date field will be overwritten to +2 h from now automatically.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _jsonController,
              enabled: !_isPushing,
              maxLines: 10,
              style: const TextStyle(fontFamily: 'Courier', fontSize: 12),
              decoration: InputDecoration(
                hintText:
                    '{\n  "schedule_id": "...",\n  "sport": "CYCLING",\n  ...\n}',
                hintStyle: TextStyle(color: Colors.grey.shade400),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.all(12),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: 'Clear',
                  onPressed: () => _jsonController.clear(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _isPushing ? null : _pushPastedJson,
              icon: _isPushing && _activeScenarioLabel == 'Pasted JSON'
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.upload_file, size: 18),
              label: const Text('Push Pasted JSON'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),

            const SizedBox(height: 24),
            const Divider(),

            // ── Section: Manage Scheduled Workouts ────────────────────────
            const SizedBox(height: 8),
            _buildManageSection(),

            const SizedBox(height: 24),
            const Divider(),

            // ── Section: Cache ────────────────────────────────────────────
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _isPushing ? null : _clearCache,
              icon: const Icon(Icons.delete_sweep),
              label: const Text('Clear Local Deduplication Cache'),
            ),

            const SizedBox(height: 24),

            // ── Section: Results ──────────────────────────────────────────
            _buildResultsPanel(),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
