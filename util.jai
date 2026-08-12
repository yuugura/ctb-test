append_with_newline :: (builder: *String_Builder, str: string, args: .. Any)
{
    text := join(str, "\n");
    append(builder, tprint(text, args));
}