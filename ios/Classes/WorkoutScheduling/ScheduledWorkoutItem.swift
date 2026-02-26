//
//  ScheduledWorkoutItem.swift
//  Runner
//
//  Created by Vinay Vudatala on 13/02/26.
//  Copyright © 2026 The Chromium Authors. All rights reserved.
//

import WorkoutKit
@available(iOS 17.0, *)
struct ScheduledWorkoutItem {
    let workout: WorkoutPlan.Workout
    let scheduledDate: Date
    let workoutModel :WorkoutInstanceModelElement
}
