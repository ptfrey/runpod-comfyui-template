# Realistic AI Mirror-Selfie Workflow

This workflow is designed to create a mirror selfie that looks like an ordinary smartphone photograph rather than a polished AI portrait. It uses **Z-Image Turbo in ComfyUI**, which offers a good balance of photorealism, speed and hardware accessibility.

Z-Image Turbo is a 6-billion-parameter distilled model designed to produce results in approximately eight sampling steps. Its developers state that it fits within 16 GB of consumer GPU memory and is particularly strong at photorealistic generation.

## Requirements

### Software

- An updated installation of **ComfyUI**
- The official **Z-Image Turbo ComfyUI workflow**
- The Z-Image Turbo diffusion model, text encoder and VAE requested by the workflow
- An image editor or ComfyUI inpainting workflow for optional corrections

The simplest installation method is to update ComfyUI, open its workflow templates, locate the Z-Image Turbo template and download the model files identified inside it. ComfyUI recommends using its latest version because older builds may be missing the necessary core nodes.

### Hardware

- **Recommended GPU:** NVIDIA GPU with 16 GB VRAM
- **System memory:** 32 GB RAM recommended
- **Storage:** Allow roughly 20–30 GB for ComfyUI, model files and generated images
- **Lower-memory alternative:** Use a quantized model or ComfyUI Cloud

A GPU with less than 16 GB may still work through quantization or CPU offloading, but it will generally run more slowly.

### Responsible use

Use the likeness of a real person only when that person is an adult and has given permission. Clearly identify the result as AI-generated when it could otherwise mislead viewers.

## Starting settings

Use these as the baseline:

| Setting | Starting value |
|---|---:|
| Model | Z-Image Turbo |
| Width | 1024 |
| Height | 1280 |
| Aspect ratio | 4:5 vertical |
| Steps | 8 |
| CFG field | 1.0 |
| Batch size | 1 |
| Number of test seeds | 8–16 |
| Negative prompt | None |
| Upscaling | Disabled during testing |

Z-Image Turbo is officially configured for eight inference steps and does not use conventional classifier-free guidance. In interfaces that still display a CFG box, use `1.0`.

Do not rely on a negative prompt for the Turbo model. Put important restrictions directly into the positive prompt instead—for example, “no beauty retouching,” “the phone does not illuminate the face,” and “physically correct mirror reflection.”

## ComfyUI workflow

### 1. Load the official template

Open ComfyUI and load the official Z-Image Turbo text-to-image workflow. Confirm that the model, text encoder and VAE nodes load without errors.

Keep the official sampler and scheduler settings for the first test. This gives you a stable baseline before adding custom nodes or community modifications.

### 2. Set the canvas

Use a vertical `1024 × 1280` canvas. A 4:5 frame resembles common social-media photography and gives the model enough room to render the subject, phone, reflected arm and bathroom environment.

Avoid beginning at an extremely high resolution. Higher resolutions can make hands, reflections and duplicated objects less stable.

### 3. Add the prompt

Paste the prompt below into the positive-prompt node. Replace the bracketed subject details while keeping the camera, lighting, reflection and environmental instructions intact.

### 4. Generate several seeds

Generate at least eight different seeds before changing the prompt. Mirror selfies contain difficult geometry, so even a strong prompt will produce some failures.

Judge the initial images primarily on:

- Correct phone and hand placement
- Plausible reflection geometry
- Natural body position
- Consistent facial and room lighting
- Coherent background objects

Do not select an image only because its face is attractive. A less polished image with correct geometry will usually look more realistic.

### 5. Refine the prompt gradually

Change one category at a time:

1. Subject and clothing
2. Pose and framing
3. Room and background objects
4. Lighting
5. Camera imperfections

Changing everything simultaneously makes it difficult to determine which words improved or damaged the result.

Community testing suggests that Z-Image Turbo responds well to detailed descriptions of an ordinary person and a specific camera type. Phrases such as “ordinary everyday appearance” and “point-and-shoot snapshot” can work better than generic terms such as “photorealistic” or “8K.”

### 6. Repair the hand and phone when necessary

When the phone or fingers are incorrect, mask and inpaint the following as one connected region:

- Phone
- Fingers
- Entire hand
- Wrist
- Part of the forearm

Correcting only individual fingers often leaves an impossible grip or a forearm that no longer connects properly.

Use a low-to-moderate inpainting denoise value, approximately `0.25–0.40`, so the structure can change without replacing the complete person.

### 7. Repair inconsistent facial lighting

A common failure is a face that appears illuminated by a nonexistent phone screen.

Mask the face, ears, hairline and upper neck together. Inpaint them with a prompt such as:

> The face is illuminated only by the overhead bathroom light, matching the shadows and color temperature on the neck, arms and room. The phone screen casts no visible light.

Do not mask only the central facial features. The face must blend with the ears, hairline and neck.

### 8. Upscale last

Only upscale after the phone, hands, reflection and lighting are correct.

Use a conservative 1.5× or 2× upscale first. Avoid aggressive face restoration and excessive sharpening because they can create plastic skin, unnaturally bright eyes and pores that are sharper than the rest of the photograph.

## Ready-to-use prompt

```text
A vertical, unedited smartphone mirror selfie of an adult
[woman/man/person] with an ordinary, believable everyday appearance,
standing naturally in a small lived-in apartment bathroom.

The subject has [describe age range, face shape, hairstyle, hair color,
build and distinguishing features]. They are wearing [describe simple
clothing with realistic wrinkles and fabric texture]. Their expression
is relaxed and neutral, with a natural asymmetrical posture and their
weight resting slightly on one leg.

The subject holds a dark modern smartphone in their right hand at chest
height. The fingers wrap naturally around the phone and the wrist and
forearm connect correctly. The phone, hand, arm, reflected body and
bathroom obey physically correct mirror geometry. There is only one
phone and one complete hand. The reflection is spatially coherent.

The composition is slightly off-center and casually framed. The phone
partially obscures the lower portion of the face without completely
covering it. One shoulder is close to the edge of the photograph. The
camera is held at a slight natural angle rather than perfectly level.

The bathroom is ordinary and genuinely lived in. A toothbrush, soap
dispenser, hair tie and folded hand towel sit on the counter. A towel
hangs slightly unevenly in the background. The objects have believable
positions and scale. Packaging is indistinct and contains no readable
text.

The mirror has a few subtle fingerprints and dried water spots, mostly
near its lower edge. The marks are restrained and do not cover the
subject.

The room is illuminated primarily by one ordinary cool-white overhead
bathroom light, with a weak warmer light entering through the doorway.
The light direction is consistent across the face, neck, hands,
clothing and room. The phone display does not cast light on the face.
There is a natural soft shadow beneath the chin and beside the nose.

Natural human skin with mild uneven coloration, restrained pores, faint
under-eye texture, tiny realistic blemishes and a few flyaway hairs.
No flawless skin, no waxy skin, no airbrushing and no beauty
retouching.

Captured as an ordinary handheld smartphone snapshot, similar to a
casual iPhone photograph. Slight edge softness, subtle sensor noise,
mild JPEG compression, realistic mobile-camera dynamic range and
natural white balance. Minimally processed and casually uploaded to
social media.

The image is not a studio portrait, not fashion photography, not CGI,
not a digital painting and not a polished advertisement. No ring light,
no dramatic cinematic lighting, no extreme depth of field, no
oversharpening, no duplicated phone, no additional fingers and no
impossible reflection.
```

## Prompting notes

The prompt intentionally describes physical causes rather than merely asking for “imperfections.” A slightly dirty mirror, one overhead fixture, casual framing and mild compression all have plausible real-world origins.

Avoid adding long strings such as:

```text
masterpiece, best quality, flawless, perfect face, cinematic,
hyperrealistic, 8K, award-winning photography, ultra-detailed skin
```

Those terms frequently encourage a polished promotional appearance—the opposite of a believable casual selfie.

For greater authenticity, introduce only a few restrained imperfections:

- One compositional imperfection: slight tilt or accidental crop
- One environmental imperfection: water spots or modest clutter
- One camera imperfection: mild noise, softness or compression

Adding heavy grain, major blur, lens flare, chromatic aberration, dirty glass and extreme compression simultaneously will look artificially distressed rather than realistic.

## Final quality check

Before accepting the image, inspect it at thumbnail size and at full resolution.

At thumbnail size, check the composition, lighting and whether the photograph immediately feels staged. At full resolution, check the fingers, phone edges, eye reflections, hairline, skin texture, room geometry and mirrored objects.

The most convincing image will usually be the one that looks pleasantly ordinary rather than technically spectacular.