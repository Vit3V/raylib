#version 300 es
precision highp float;
precision highp int;

// Input vertex attributes (from vertex shader)
in vec2 fragTexCoord;
in vec4 fragColor;

// Input uniform values
uniform sampler2D texture0;
uniform sampler2D mask;
uniform int frame;

// Output fragment color
out vec4 finalColor;

void main()
{
    vec4 maskColour = texture(mask, fragTexCoord + vec2(sin(-float(frame)/150.0)/10.0, cos(-float(frame)/170.0)/10.0));
    if (maskColour.r < 0.25) discard;
    vec4 texelColor = texture(texture0, fragTexCoord + vec2(sin(float(frame)/90.0)/8.0, cos(float(frame)/60.0)/8.0));

    finalColor = texelColor*maskColour;
}
