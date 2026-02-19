# ssilvb-compositor-godot
An upgraded version of SSIL (SSIL-VB) and SSAO (GTAO-VB) that is similar to the performance of Godot's current version. This is the testbed before I integrate it into the source code

To use this, you need to add a compositor to your world environment, then add the "SSGI" and "SGGIBlurPass" as effects, in that order (SSGI class as the first effect, SSGIBlurPass as the second). You will need to set the "gi settings" parameter to the gi_settings resource once you do so. The performance difference from what I have tested (this is comparing mine with 32 samples, 1 slice to ultra settings no half res ssil + ssao) is about a 0.3ms difference, which I think is decent for such an effect.

Currently the temporal accumulation isn't really accumulation, it just alters the noise between frames for now because I got a little lazy lol.. Another thing to note is that both the .glsl files CANNOT be inside any folders after res:// unless you change the source locations in the gd script. For ease of use, ensure you have the file paths as these when you import them: "res://ssilvb_blur.glsl", "res://ssilvb.glsl". 
There are still some noise artifacts, the blur sort of sucks, and I need to get temporal working, as well as fix some bugs I may find, but overall I'd say its a solid improvement. I am hoping to get performance matching the current ssil + ssao combo, if not faster.

## SSILVB vs SSIL + SSAO
![alt text](<Screenshot 2026-02-18 155253.png>)
![alt text](<Screenshot 2026-02-18 155416.png>)