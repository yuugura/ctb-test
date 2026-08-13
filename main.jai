#import "Basic";
#import "raylib";
#import "Math";
#import "File";
#import "String";

#load "game.jai";

SCREEN_WIDTH  :: 800;
SCREEN_HEIGHT :: 450;

main :: () {
    InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, get_c_string("osu!Catch - Catcher"));
    defer CloseWindow();

    SetTargetFPS(60);

    using game := init_game("resources/test_map.osu");
    defer UnloadTexture(game.catcher_texture);

    SetExitKey(.KEY_NULL); // Auto: So the window doesn't close when pressing esc key

    while !WindowShouldClose() {
        reset_temporary_storage(); // Auto: We need this if you're going to use tprint(), otherwise it will lead to memory leak because you keep allocating memory for string but never clears them. Read temporary storage in how_to for details. 

        if game.state == {
            case .Playing; update_game(*game);
            case .Paused; if IsKeyPressed(.KEY_ESCAPE) game.state = .Playing;
        }
        
        // 7. Draw
        PushDrawing();

        ClearBackground(RAYWHITE); // Auto: wtf who tf plays osu with full white background
        render_game(*game);

        scheme_name := "Arrows + LShift";
        if input_scheme == .WASD scheme_name = "A/D + RShift";

        DrawText(get_c_string(tprint("Circle Size: % (- / +)", difficulty.circle_size)), 10, 10, 20, BLACK);
        DrawText(get_c_string(tprint("Keybinds: % (Tab to switch)", scheme_name)), 10, 30, 20, BLACK);
        DrawText(get_c_string(tprint("Caught: %   Missed: %", caught_count, missed_count)), 10, 50, 20, BLACK);

        if game.state == .Paused {
            font_size := 50;
            paused_text := temp_c_string("PAUSED");
            text_width := MeasureText(paused_text, xx font_size);
            DrawText("PAUSED", (SCREEN_WIDTH - text_width) / 2, cast(s32)(SCREEN_HEIGHT - font_size) / 2, xx font_size, BLACK);
        }
            
    }
}
