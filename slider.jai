// Slider -> catch-object conversion.
//
// osu!catch turns each slider into a sequence of catchable objects along the
// slider's path: a Fruit at the head, a Fruit at every repeat and at the
// tail, and a Droplet ("big droplet" / slider tick) at every SliderTickRate
// interval in between. This mirrors ppy/osu's JuiceStream.CreateNestedHitObjects
// + SliderEventGenerator, simplified to only track the x position (the only
// thing that matters for catcher gameplay) instead of a full 2D path.
//
// build_catch_objects() flattens hit circles and slider nested objects into
// one time-ordered list that both the spawn walk (update_fruits) and the
// hyperdash pass (compute_hyperdash_targets) drive off of, so slider ticks
// participate in hyperdash gap calculations exactly like hit circles do.

Catch_Object_Kind :: enum u8 {
    Fruit;   // hit circles, slider heads/repeats/tails
    Droplet; // slider ticks ("big droplets")
}

Catch_Object :: struct {
    time: float; // ms
    x:    float; // osu!px

    // Filled in by compute_hyperdash_targets, mirroring Osu_Hit_Object's
    // equivalent fields.
    is_hyperdash:       bool;
    hyperdash_target_x: float;
    hyperdash_speed:    float;

    kind: Catch_Object_Kind;
}

add_catch_object :: (out: *[..] Catch_Object, time: float, x: float, kind: Catch_Object_Kind) {
    obj: Catch_Object;
    obj.time = time;
    obj.x = x;
    obj.kind = kind;
    array_add(out, obj);
}

build_catch_objects :: (beatmap: *Osu_File) -> [..] Catch_Object {
    objects: [..] Catch_Object;

    for * hit_object: beatmap.hit_objects {
        if has_hit_object_type(hit_object, .Hit_Circle) {
            add_catch_object(*objects, cast(float) hit_object.time, cast(float) hit_object.x, .Fruit);
        } else if has_hit_object_type(hit_object, .Slider) {
            append_slider_catch_objects(beatmap, hit_object, *objects);
        }
        // Spinners produce no catchable fruit in osu!catch -- skipped.
    }

    // Hit objects in a .osu file are time-ordered, but guard against a
    // pathological map stacking objects unusually closely by sorting once
    // after generation rather than assuming order holds.
    quick_sort(objects, (a: Catch_Object, b: Catch_Object) -> int {
        if a.time < b.time return -1;
        if a.time > b.time return 1;
        return 0;
    });

    return objects;
}

// --- Slider timing (osu.ppy.sh/wiki/en/Beatmap/Slider) ---------------------

// Returns the ms-per-beat and slider-velocity multiplier in effect at `time`,
// from the last uninherited (red) and inherited (green) timing points at or
// before it, respectively.
timing_at :: (beatmap: *Osu_File, time: int) -> (beat_length_ms: float, sv_multiplier: float) {
    beat_length_ms: float = 428.571; // sane fallback if the map has no timing points at all
    sv_multiplier:  float = 1.0;

    for beatmap.timing_points {
        if it.time > time continue;
        if it.uninherited {
            beat_length_ms = it.beat_length;
            sv_multiplier = 1.0;
        } else if it.beat_length < 0 {
            sv_multiplier = clamp(-100.0 / it.beat_length, 0.1, 10.0);
        } else {
            sv_multiplier = 1.0;
        }
    }

    return beat_length_ms, sv_multiplier;
}

slider_timing :: (beatmap: *Osu_File, hit_object: *Osu_Hit_Object) -> (velocity_px_per_ms: float, span_duration_ms: float, tick_distance_px: float) {
    beat_length_ms, sv_multiplier := timing_at(beatmap, hit_object.time);
    if beat_length_ms <= 0 beat_length_ms = 428.571;

    slider_multiplier := beatmap.difficulty_info.SliderMultiplier;
    tick_rate := beatmap.difficulty_info.SliderTickRate;
    if tick_rate <= 0 tick_rate = 1;

    scoring_distance := 100.0 * slider_multiplier * sv_multiplier;
    velocity := scoring_distance / beat_length_ms;
    if velocity <= 0 velocity = 0.1;

    span_duration := hit_object.slider_params.length / velocity;
    tick_distance := scoring_distance / tick_rate;

    return velocity, span_duration, tick_distance;
}

// --- Slider path sampling ---------------------------------------------------
// We only need the x coordinate for gameplay, but computing the real 2D path
// is barely more work than a 1D one (Bezier/Catmull are affine per-component
// anyway, and the perfect-circle arc needs 2D regardless) and keeps the math
// recognizable against osu's own PathApproximator, so we track full Vector2s
// and take .x where fruits/droplets are actually placed.

BEZIER_SAMPLES :: 50; // per bezier segment
CATMULL_SAMPLES :: 20; // per catmull-rom segment
ARC_SAMPLES :: 50; // per circular arc
MAX_BEZIER_SEGMENT_POINTS :: 64;

Slider_Path :: struct {
    points:       [..] Vector2; // sampled polyline approximating the curve
    cumulative:   [..] float;   // cumulative arc length up to points[i], same count as points
    total_length: float;
}

free_slider_path :: (path: *Slider_Path) {
    array_free(path.points);
    array_free(path.cumulative);
}

parse_curve_point :: (s: string) -> Vector2 {
    parts := split(s, ":");
    if parts.count < 2 return Vector2.{0, 0};
    return Vector2.{ string_to_float(parts[0]), string_to_float(parts[1]) };
}

vector2_equal :: (a: Vector2, b: Vector2) -> bool {
    return a.x == b.x && a.y == b.y;
}

// De Casteljau evaluation of a single Bezier segment (any degree) at t.
bezier_point :: (control: [] Vector2, t: float) -> Vector2 {
    work: [MAX_BEZIER_SEGMENT_POINTS] Vector2;
    n := control.count;
    if n > MAX_BEZIER_SEGMENT_POINTS n = MAX_BEZIER_SEGMENT_POINTS;
    for i: 0..n-1 work[i] = control[i];

    count := n;
    while count > 1 {
        for i: 0..count-2 work[i] = Vector2Lerp(work[i], work[i+1], t);
        count -= 1;
    }
    return work[0];
}

append_bezier_segment :: (segment: [] Vector2, output: *[..] Vector2, is_first_segment: bool) {
    if segment.count == 0 return;
    if segment.count == 1 {
        if is_first_segment array_add(output, segment[0]);
        return;
    }

    start_step := ifx is_first_segment then 0 else 1;
    for step: start_step..BEZIER_SAMPLES {
        t := cast(float) step / cast(float) BEZIER_SAMPLES;
        array_add(output, bezier_point(segment, t));
    }
}

// osu splits a Bezier curve's control points into separate segments at any
// repeated ("red anchor") point, so sliders can have sharp corners.
approximate_bezier :: (control: [] Vector2, output: *[..] Vector2) {
    if control.count == 0 return;
    if control.count == 1 {
        array_add(output, control[0]);
        return;
    }

    first_segment := true;
    segment_start := 0;
    for i: 0..control.count - 1 {
        is_last := (i == control.count - 1);
        is_duplicate := !is_last && vector2_equal(control[i], control[i+1]);

        if is_last || is_duplicate {
            segment := array_view(control, segment_start, i - segment_start + 1);
            append_bezier_segment(segment, output, first_segment);
            first_segment = false;
            segment_start = i + 1;
        }
    }
}

catmull_point :: (p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2 {
    t2 := t * t;
    t3 := t2 * t;
    x := 0.5 * ((2*p1.x) + (-p0.x+p2.x)*t + (2*p0.x-5*p1.x+4*p2.x-p3.x)*t2 + (-p0.x+3*p1.x-3*p2.x+p3.x)*t3);
    y := 0.5 * ((2*p1.y) + (-p0.y+p2.y)*t + (2*p0.y-5*p1.y+4*p2.y-p3.y)*t2 + (-p0.y+3*p1.y-3*p2.y+p3.y)*t3);
    return Vector2.{ x, y };
}

// Legacy "C" curve type: Catmull-Rom spline through all control points,
// reflecting the first/last point as a virtual neighbor at each end.
approximate_catmull :: (control: [] Vector2, output: *[..] Vector2) {
    if control.count == 0 return;
    if control.count == 1 {
        array_add(output, control[0]);
        return;
    }

    for i: 0..control.count - 2 {
        p0 := ifx i > 0 then control[i-1] else control[i];
        p1 := control[i];
        p2 := control[i+1];
        p3 := ifx i < control.count - 2 then control[i+2] else p2;

        start_step := ifx i > 0 then 1 else 0;
        for step: start_step..CATMULL_SAMPLES {
            t := cast(float) step / cast(float) CATMULL_SAMPLES;
            array_add(output, catmull_point(p0, p1, p2, p3, t));
        }
    }
}

// "P" curve type: circular arc through exactly 3 points. Ported from
// ppy/osu's CircularArcApproximator.CreateArc -- the s/t/u weighted
// circumcenter avoids a naive determinant division blowing up near-collinear
// points. Returns false (leaving `output` untouched) if the 3 points are
// degenerate, in which case the caller should fall back to treating them as
// a Bezier curve, matching real osu.
approximate_circular_arc :: (p0: Vector2, p1: Vector2, p2: Vector2, output: *[..] Vector2) -> bool {
    a_sq := Vector2LengthSqr(Vector2Subtract(p1, p2));
    b_sq := Vector2LengthSqr(Vector2Subtract(p0, p2));
    c_sq := Vector2LengthSqr(Vector2Subtract(p0, p1));

    EPSILON :: 0.0001;
    if a_sq < EPSILON || b_sq < EPSILON || c_sq < EPSILON return false;

    s := a_sq * (b_sq + c_sq - a_sq);
    t := b_sq * (a_sq + c_sq - b_sq);
    u := c_sq * (a_sq + b_sq - c_sq);
    sum := s + t + u;
    if abs(sum) < EPSILON return false;

    centre := Vector2.{
        (s*p0.x + t*p1.x + u*p2.x) / sum,
        (s*p0.y + t*p1.y + u*p2.y) / sum,
    };

    dA := Vector2Subtract(p0, centre);
    dC := Vector2Subtract(p2, centre);
    radius := Vector2Length(dA);
    if radius < EPSILON return false;

    theta_start := atan2(dA.y, dA.x);
    theta_end   := atan2(dC.y, dC.x);
    while theta_end < theta_start theta_end += 2.0 * PI;

    dir: float = 1;
    theta_range := theta_end - theta_start;

    // Which way around the circle to go -- the arc must pass through p1.
    ortho_a_to_c := Vector2Subtract(p2, p0);
    ortho_a_to_c = Vector2.{ ortho_a_to_c.y, -ortho_a_to_c.x };
    if Vector2DotProduct(ortho_a_to_c, Vector2Subtract(p1, p0)) < 0 {
        dir = -1;
        theta_range = 2.0 * PI - theta_range;
    }

    for step: 0..ARC_SAMPLES {
        frac := cast(float) step / cast(float) ARC_SAMPLES;
        theta := theta_start + dir * frac * theta_range;
        array_add(output, Vector2.{ centre.x + radius * cos(theta), centre.y + radius * sin(theta) });
    }

    return true;
}

build_slider_path :: (hit_object: *Osu_Hit_Object) -> Slider_Path {
    control: [..] Vector2;
    array_add(*control, Vector2.{ cast(float) hit_object.x, cast(float) hit_object.y });
    for hit_object.slider_params.curve_points array_add(*control, parse_curve_point(it));
    defer array_free(control);

    raw: [..] Vector2;

    curve_type := hit_object.slider_params.curve_type;
    if curve_type == "L" {
        for control array_add(*raw, it);
    } else if curve_type == "C" {
        approximate_catmull(control, *raw);
    } else if curve_type == "P" && control.count == 3 {
        if !approximate_circular_arc(control[0], control[1], control[2], *raw) {
            approximate_bezier(control, *raw);
        }
    } else {
        approximate_bezier(control, *raw); // "B", and malformed "P"
    }

    if raw.count == 0 array_add(*raw, control[0]);

    path: Slider_Path;
    path.points = raw;
    array_resize(*path.cumulative, raw.count);

    total: float = 0;
    path.cumulative[0] = 0;
    for i: 1..raw.count - 1 {
        total += Vector2Distance(raw[i-1], raw[i]);
        path.cumulative[i] = total;
    }
    path.total_length = total;

    return path;
}

// progress: 0..1 fraction of the slider's own physical path (head to tail),
// independent of which direction a given span is currently traveling.
slider_position_at :: (path: *Slider_Path, progress: float) -> Vector2 {
    if path.points.count == 1 return path.points[0];

    p := clamp(progress, 0.0, 1.0);
    if path.total_length <= 0 return path.points[0];

    target_distance := p * path.total_length;
    if target_distance <= 0 return path.points[0];
    if target_distance >= path.total_length return path.points[path.points.count - 1];

    for i: 1..path.cumulative.count - 1 {
        if path.cumulative[i] >= target_distance {
            seg_len := path.cumulative[i] - path.cumulative[i-1];
            t := ifx seg_len > 0 then (target_distance - path.cumulative[i-1]) / seg_len else 0.0;
            return Vector2Lerp(path.points[i-1], path.points[i], t);
        }
    }
    return path.points[path.points.count - 1];
}

// --- Slider -> catch-object flattening --------------------------------------
// Mirrors ppy/osu's SliderEventGenerator: a Fruit at the head, a Droplet at
// every tick_distance along each span, and a Fruit at every repeat and at
// the final tail.
append_slider_catch_objects :: (beatmap: *Osu_File, hit_object: *Osu_Hit_Object, out: *[..] Catch_Object) {
    path := build_slider_path(hit_object);
    defer free_slider_path(*path);

    velocity, span_duration, tick_distance := slider_timing(beatmap, hit_object);
    span_count := max(1, hit_object.slider_params.slides);
    field_length := hit_object.slider_params.length;

    add_catch_object(out, cast(float) hit_object.time, path.points[0].x, .Fruit);

    if tick_distance > 0 && field_length > 0 {
        min_distance_from_end := velocity * 10.0; // osu skips ticks within the last 10ms of a span

        for span: 0..span_count - 1 {
            span_start_time := cast(float) hit_object.time + span_duration * cast(float) span;
            reversed := (span % 2) == 1;

            distance := tick_distance;
            while distance < field_length - min_distance_from_end {
                // path_progress is elapsed-time fraction within the span --
                // always proportional to distance traveled regardless of
                // direction. physical_progress is where that puts us on the
                // path itself, which *does* flip for a reversed span.
                path_progress := distance / field_length;
                physical_progress := ifx reversed then 1.0 - path_progress else path_progress;

                pos := slider_position_at(*path, physical_progress);
                add_catch_object(out, span_start_time + path_progress * span_duration, pos.x, .Droplet);

                distance += tick_distance;
            }

            end_progress := ifx reversed then 0.0 else 1.0;
            end_pos := slider_position_at(*path, end_progress);
            add_catch_object(out, span_start_time + span_duration, end_pos.x, .Fruit);
        }
    } else {
        // Degenerate (zero-length or zero-tick-distance) slider -- still
        // spawn a tail so it remains catchable.
        end_time := cast(float) hit_object.time + span_duration * cast(float) span_count;
        add_catch_object(out, end_time, path.points[0].x, .Fruit);
    }
}
