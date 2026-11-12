#version 300 es
precision highp float;
precision highp int;

// Input vertex attributes (from vertex shader)
in vec2 fragTexCoord;
in vec4 fragColor;

// Input uniform values
uniform sampler2D texture0;
uniform vec4 colDiffuse;

// Output fragment color
out vec4 finalColor;

// NOTE: Add your custom variables here

// NOTE: Render size values must be passed from code
const float renderWidth = 800.0;
const float renderHeight = 450.0;

const float pixelWidth = 5.0;
const float pixelHeight = 5.0;

void main()
{
    float dx = pixelWidth*(1.0/renderWidth);
    float dy = pixelHeight*(1.0/renderHeight);

    vec2 coord = vec2(dx*floor(fragTexCoord.x/dx), dy*floor(fragTexCoord.y/dy));

    vec3 tc = texture(texture0, coord).rgb;

    finalColor = vec4(tc, 1.0);
}