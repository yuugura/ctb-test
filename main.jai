#import "raylib";
#import "Math";

SCREEN_WIDTH  :: 800;
SCREEN_HEIGHT :: 450;
CATCHER_SPEED :: 400.0; // pixels per second

// Catcher should read as a small object near the floor of the playfield,
// not dominate the window -- target its drawn height as a fraction of the window.
CATCHER_HEIGHT_FRACTION :: 0.30;
CATCHER_BOTTOM_MARGIN   :: 20.0;

main :: () {
    InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, get_c_string("osu!Catch - Catcher"));
    defer CloseWindow();

    SetTargetFPS(60);

    catcher_texture := LoadTexture(get_c_string("resources/catcher.png"));
    defer UnloadTexture(catcher_texture);

    catcher_scale  := (SCREEN_HEIGHT * CATCHER_HEIGHT_FRACTION) / cast(float) catcher_texture.height;
    catcher_width  := cast(float) catcher_texture.width  * catcher_scale;
    catcher_height := cast(float) catcher_texture.height * catcher_scale;

    catcher_x := (SCREEN_WIDTH - catcher_width) / 2;
    catcher_y := SCREEN_HEIGHT - catcher_height - CATCHER_BOTTOM_MARGIN;

    while !WindowShouldClose() {
        dt := GetFrameTime();

        if IsKeyDown(.KEY_LEFT)  catcher_x -= CATCHER_SPEED * dt;
        if IsKeyDown(.KEY_RIGHT) catcher_x += CATCHER_SPEED * dt;

        min_x := 0.0;
        max_x := SCREEN_WIDTH - catcher_width;
        if catcher_x < min_x catcher_x = min_x;
        if catcher_x > max_x catcher_x = max_x;

        PushDrawing();

        ClearBackground(RAYWHITE);
        DrawTextureEx(catcher_texture, Vector2.{ catcher_x, catcher_y }, 0, catcher_scale, WHITE);
    }
}
