/**
 * CUDA Color Palette Optimizer v2.5 - Golden yellow, brighter red
 *
 * Uses genetic algorithm to find optimal 16-color terminal palettes.
 *
 * Constraints:
 *   1. Base colors (1-6) on black with PER-COLOR minimums:
 *      - Red >= 5.5 (force brighter)
 *      - Green >= 4.5 (needs higher contrast)
 *      - Yellow, Blue, Magenta, Cyan >= 3.5
 *      - All colors <= 7.5
 *      - Yellow forced to golden range (high R, capped G, minimal B)
 *   2. Bright on regular (br.X on X): CR >= 3.0
 *   3. Cyan on blue: DISABLED (only MC cursor uses this)
 *
 * Fixed colors:
 *   - Black: #000000
 *   - White: #bfbfbf
 *   - Br.Black: #404040
 *   - Br.White: #ffffff
 *
 * Perceptual considerations (Helmholtz-Kohlrausch effect):
 *   - Saturated red/blue/magenta appear brighter than luminance suggests
 *   - Yellow/green appear closer to their calculated luminance
 *   - Blue hues are poorly predicted by standard color spaces
 *
 * Build: nvcc -O3 -o color-optimizer2 color-optimizer2.cu -lcurand
 * Run:   ./color-optimizer2 -g 5000 -p 200000
 */

#include <cuda_runtime.h>
#include <curand_kernel.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <vector>
#include <random>

// =============================================================================
// Color indices
// =============================================================================
enum ColorIndex {
    BLACK = 0, RED, GREEN, YELLOW, BLUE, MAGENTA, CYAN, WHITE,
    BR_BLACK, BR_RED, BR_GREEN, BR_YELLOW, BR_BLUE, BR_MAGENTA, BR_CYAN, BR_WHITE
};

// =============================================================================
// Constraints
// =============================================================================
#define MAX_BASE_ON_BLACK 7.5f
#define MIN_BRIGHT_ON_REGULAR 3.0f
// Cyan-on-blue constraint disabled - only MC cursor uses this combination

// Per-color minimum contrast on black background
// Red and green get higher minimums since they appear darker perceptually
// Order: RED, GREEN, YELLOW, BLUE, MAGENTA, CYAN (indices 1-6)
__constant__ float d_min_contrast[6] = {
    5.5f,   // RED - force brighter red
    4.5f,   // GREEN - needs higher minimum
    3.5f,   // YELLOW - fine as is
    3.5f,   // BLUE - fine as is
    3.5f,   // MAGENTA - fine as is
    3.5f,   // CYAN - fine as is
};

// Host-side copy for printing
const float h_min_contrast[6] = {5.5f, 4.5f, 3.5f, 3.5f, 3.5f, 3.5f};

// =============================================================================
// Color character definitions
// =============================================================================
// Each color has RGB ranges that define its "character" - what makes it look
// like that color. The optimizer searches within these ranges.
//
// Perceptual notes (Helmholtz-Kohlrausch effect):
// - Saturated red/blue/magenta appear ~10-20% brighter than luminance predicts
// - Yellow/green track closer to calculated luminance
// - We compensate by allowing slightly lower luminance for red/blue/magenta

struct ColorRange {
    float r_min, r_max;
    float g_min, g_max;
    float b_min, b_max;
    bool fixed;
};

// Fixed colors
#define BLACK_RGB     0,   0,   0,   0,   0,   0, true
#define WHITE_RGB   191, 191, 191, 191, 191, 191, true   // #bfbfbf
#define BR_BLACK_RGB 64,  64,  64,  64,  64,  64, true   // #404040
#define BR_WHITE_RGB 255, 255, 255, 255, 255, 255, true  // #ffffff

// Color character ranges
// Format: r_min, r_max, g_min, g_max, b_min, b_max, fixed
const ColorRange color_ranges[16] = {
    // Base colors (indices 0-7)
    {BLACK_RGB},                                    // 0: BLACK
    {140, 255,   0,  80,   0,  80, false},          // 1: RED - high R, low G, low B
    {  0, 100,  80, 255,   0, 100, false},          // 2: GREEN - low R, high G, low B
    {200, 255, 160, 220,   0,  20, false},          // 3: YELLOW - golden: high R, capped G, minimal B
    {  0, 100,   0, 150, 140, 255, false},          // 4: BLUE - low R, low-med G, high B
    {140, 255,   0, 100, 140, 255, false},          // 5: MAGENTA - high R, low G, high B
    {  0, 100,  80, 255,  80, 255, false},          // 6: CYAN - low R, med-high G, med-high B
    {WHITE_RGB},                                    // 7: WHITE

    // Bright colors (indices 8-15)
    {BR_BLACK_RGB},                                 // 8: BR_BLACK
    {180, 255,  80, 180,  80, 180, false},          // 9: BR_RED - brighter red
    { 80, 180, 160, 255,  80, 180, false},          // 10: BR_GREEN - brighter green
    {180, 255, 180, 255,  80, 180, false},          // 11: BR_YELLOW - brighter yellow
    { 80, 180, 120, 220, 180, 255, false},          // 12: BR_BLUE - brighter blue
    {180, 255,  80, 180, 180, 255, false},          // 13: BR_MAGENTA - brighter magenta
    { 80, 180, 180, 255, 180, 255, false},          // 14: BR_CYAN - brighter cyan
    {BR_WHITE_RGB},                                 // 15: BR_WHITE
};

// Device constant memory for color ranges
__constant__ ColorRange d_ranges[16];

// =============================================================================
// CUDA Device Functions
// =============================================================================

__device__ float linearize(float c) {
    float c_srgb = c / 255.0f;
    if (c_srgb <= 0.04045f) {
        return c_srgb / 12.92f;
    }
    return powf((c_srgb + 0.055f) / 1.055f, 2.4f);
}

__device__ float luminance(float r, float g, float b) {
    return 0.2126f * linearize(r) + 0.7152f * linearize(g) + 0.0722f * linearize(b);
}

__device__ float contrast_ratio(float r1, float g1, float b1, float r2, float g2, float b2) {
    float l1 = luminance(r1, g1, b1);
    float l2 = luminance(r2, g2, b2);
    if (l1 > l2) {
        return (l1 + 0.05f) / (l2 + 0.05f);
    }
    return (l2 + 0.05f) / (l1 + 0.05f);
}

// =============================================================================
// OKLCH Color Space Functions
// =============================================================================
// OKLCH provides perceptually uniform hue and chroma, better than HSL/HSV
// Reference: https://bottosson.github.io/posts/oklab/

__device__ void rgb_to_oklab(float r, float g, float b, float* L, float* a, float* ok_b) {
    // sRGB to linear RGB
    float lr = linearize(r);
    float lg = linearize(g);
    float lb = linearize(b);

    // Linear RGB to LMS (cone response)
    float l = 0.4122214708f * lr + 0.5363325363f * lg + 0.0514459929f * lb;
    float m = 0.2119034982f * lr + 0.6806995451f * lg + 0.1073969566f * lb;
    float s = 0.0883024619f * lr + 0.2817188376f * lg + 0.6299787005f * lb;

    // Cube root
    float l_ = cbrtf(l);
    float m_ = cbrtf(m);
    float s_ = cbrtf(s);

    // LMS' to Oklab
    *L = 0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_;
    *a = 1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_;
    *ok_b = 0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_;
}

__device__ void rgb_to_oklch(float r, float g, float b, float* L, float* C, float* H) {
    float ok_a, ok_b;
    rgb_to_oklab(r, g, b, L, &ok_a, &ok_b);

    // Convert to polar (LCH)
    *C = sqrtf(ok_a * ok_a + ok_b * ok_b);
    *H = atan2f(ok_b, ok_a);  // Radians, -π to π

    // Convert to degrees 0-360
    *H = *H * 180.0f / 3.14159265f;
    if (*H < 0) *H += 360.0f;
}

// Perceptual distance in Oklab space (Euclidean)
__device__ float oklab_distance(float r1, float g1, float b1, float r2, float g2, float b2) {
    float L1, a1, b1_ok;
    float L2, a2, b2_ok;
    rgb_to_oklab(r1, g1, b1, &L1, &a1, &b1_ok);
    rgb_to_oklab(r2, g2, b2, &L2, &a2, &b2_ok);

    float dL = L1 - L2;
    float da = a1 - a2;
    float db = b1_ok - b2_ok;

    return sqrtf(dL * dL + da * da + db * db);
}

// Angular distance between two hues (handles wraparound)
__device__ float hue_distance(float h1, float h2) {
    float diff = fabsf(h1 - h2);
    if (diff > 180.0f) diff = 360.0f - diff;
    return diff;
}

// =============================================================================
// CUDA Kernels
// =============================================================================

__global__ void init_curand(curandState* states, unsigned long seed, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        curand_init(seed, idx, 0, &states[idx]);
    }
}

__global__ void init_population(float* palettes, curandState* states, int n_palettes) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n_palettes) return;

    curandState localState = states[idx];

    for (int color = 0; color < 16; color++) {
        ColorRange range = d_ranges[color];
        int base = idx * 16 * 3 + color * 3;

        if (range.fixed) {
            palettes[base + 0] = range.r_min;
            palettes[base + 1] = range.g_min;
            palettes[base + 2] = range.b_min;
        } else {
            palettes[base + 0] = range.r_min + curand_uniform(&localState) * (range.r_max - range.r_min);
            palettes[base + 1] = range.g_min + curand_uniform(&localState) * (range.g_max - range.g_min);
            palettes[base + 2] = range.b_min + curand_uniform(&localState) * (range.b_max - range.b_min);
        }
    }

    states[idx] = localState;
}

__global__ void evaluate_fitness(float* palettes, float* fitness, int n_palettes) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n_palettes) return;

    float score = 0.0f;
    int base = idx * 16 * 3;

    // =========================================================================
    // CONSTRAINT 1: Base colors (1-6) on black with per-color minimums
    // =========================================================================
    for (int fg = 1; fg <= 6; fg++) {
        int fg_base = base + fg * 3;
        int bg_base = base + 0 * 3;  // Black

        float cr = contrast_ratio(
            palettes[fg_base + 0], palettes[fg_base + 1], palettes[fg_base + 2],
            palettes[bg_base + 0], palettes[bg_base + 1], palettes[bg_base + 2]
        );

        // Get per-color minimum (fg index 1-6 maps to d_min_contrast[0-5])
        float min_cr = d_min_contrast[fg - 1];

        if (cr >= min_cr && cr <= MAX_BASE_ON_BLACK) {
            // Within range - reward being closer to middle of range
            float mid = (min_cr + MAX_BASE_ON_BLACK) / 2.0f;
            float distance_from_mid = fabsf(cr - mid);
            score += 100.0f - distance_from_mid * 10.0f;
        } else if (cr < min_cr) {
            // Too dark - heavy penalty
            score -= (min_cr - cr) * 200.0f;
        } else {
            // Too bright - heavy penalty
            score -= (cr - MAX_BASE_ON_BLACK) * 200.0f;
        }
    }

    // =========================================================================
    // CONSTRAINT 2: Bright on regular (br.X on X) >= 3.0
    // =========================================================================
    for (int i = 1; i <= 6; i++) {
        int reg_base = base + i * 3;
        int brt_base = base + (i + 8) * 3;

        float cr = contrast_ratio(
            palettes[brt_base + 0], palettes[brt_base + 1], palettes[brt_base + 2],
            palettes[reg_base + 0], palettes[reg_base + 1], palettes[reg_base + 2]
        );

        if (cr >= MIN_BRIGHT_ON_REGULAR) {
            score += 50.0f + cr * 5.0f;  // Reward exceeding minimum
        } else {
            score -= (MIN_BRIGHT_ON_REGULAR - cr) * 200.0f;  // Heavy penalty
        }
    }

    // CONSTRAINT 3: Cyan on blue - DISABLED (only MC cursor uses this)

    // =========================================================================
    // BONUS: Color distinctiveness
    // =========================================================================
    // Reward pairs of different base colors being distinguishable
    for (int i = 1; i <= 6; i++) {
        for (int j = i + 1; j <= 6; j++) {
            int i_base = base + i * 3;
            int j_base = base + j * 3;

            float cr = contrast_ratio(
                palettes[i_base + 0], palettes[i_base + 1], palettes[i_base + 2],
                palettes[j_base + 0], palettes[j_base + 1], palettes[j_base + 2]
            );

            // Small bonus for inter-color contrast (helps distinguish colors)
            score += cr * 2.0f;
        }
    }

    // =========================================================================
    // BONUS: Bright colors on black
    // =========================================================================
    for (int fg = 9; fg <= 14; fg++) {
        int fg_base = base + fg * 3;
        int bg_base = base + 0 * 3;

        float cr = contrast_ratio(
            palettes[fg_base + 0], palettes[fg_base + 1], palettes[fg_base + 2],
            palettes[bg_base + 0], palettes[bg_base + 1], palettes[bg_base + 2]
        );

        // Bright colors should have good contrast on black
        if (cr >= 7.0f) {
            score += 20.0f;
        }
        score += cr * 1.0f;
    }

    // =========================================================================
    // OKLCH: Hue spacing for base colors (1-6)
    // =========================================================================
    // Ideal: 6 colors evenly spaced = 60° apart
    // We reward minimum hue distance between any two colors
    {
        float hues[6];
        float chromas[6];
        float lightnesses[6];

        // Extract OKLCH values for base colors (1-6)
        for (int i = 0; i < 6; i++) {
            int c_base = base + (i + 1) * 3;
            rgb_to_oklch(
                palettes[c_base + 0], palettes[c_base + 1], palettes[c_base + 2],
                &lightnesses[i], &chromas[i], &hues[i]
            );
        }

        // Reward good hue spacing between all pairs
        float min_hue_dist = 360.0f;
        for (int i = 0; i < 6; i++) {
            for (int j = i + 1; j < 6; j++) {
                float hdist = hue_distance(hues[i], hues[j]);
                if (hdist < min_hue_dist) {
                    min_hue_dist = hdist;
                }
            }
        }

        // Ideal minimum distance for 6 colors would be 60°
        // Reward getting close to that
        if (min_hue_dist >= 30.0f) {
            score += min_hue_dist * 2.0f;  // Up to 120 points for 60° spacing
        } else {
            score -= (30.0f - min_hue_dist) * 5.0f;  // Penalty for too close
        }

        // Bonus for good chroma (saturation) - avoid washed out colors
        for (int i = 0; i < 6; i++) {
            if (chromas[i] >= 0.1f) {
                score += chromas[i] * 50.0f;  // Reward saturation
            }
        }
    }

    // =========================================================================
    // OKLCH: Perceptual distance between base colors
    // =========================================================================
    // Use Oklab distance for better perceptual uniformity than contrast ratio
    {
        float min_oklab_dist = 1000.0f;
        for (int i = 1; i <= 6; i++) {
            for (int j = i + 1; j <= 6; j++) {
                int i_base = base + i * 3;
                int j_base = base + j * 3;

                float dist = oklab_distance(
                    palettes[i_base + 0], palettes[i_base + 1], palettes[i_base + 2],
                    palettes[j_base + 0], palettes[j_base + 1], palettes[j_base + 2]
                );

                if (dist < min_oklab_dist) {
                    min_oklab_dist = dist;
                }
            }
        }

        // Reward minimum perceptual distance (0.15 is good separation in Oklab)
        if (min_oklab_dist >= 0.15f) {
            score += min_oklab_dist * 200.0f;
        } else {
            score -= (0.15f - min_oklab_dist) * 500.0f;  // Heavy penalty for similar colors
        }
    }

    // =========================================================================
    // OKLCH: Bright colors should match hue of their base counterparts
    // =========================================================================
    {
        for (int i = 1; i <= 6; i++) {
            int base_idx = base + i * 3;
            int bright_idx = base + (i + 8) * 3;

            float L1, C1, H1, L2, C2, H2;
            rgb_to_oklch(palettes[base_idx + 0], palettes[base_idx + 1], palettes[base_idx + 2],
                         &L1, &C1, &H1);
            rgb_to_oklch(palettes[bright_idx + 0], palettes[bright_idx + 1], palettes[bright_idx + 2],
                         &L2, &C2, &H2);

            // Reward hue similarity between base and bright version
            float hdist = hue_distance(H1, H2);
            if (hdist <= 30.0f) {
                score += (30.0f - hdist) * 2.0f;  // Up to 60 points for matching hue
            } else {
                score -= (hdist - 30.0f) * 3.0f;  // Penalty for hue drift
            }

            // Bright should have higher lightness
            if (L2 > L1) {
                score += 20.0f;
            }
        }
    }

    fitness[idx] = score;
}

__global__ void crossover_and_mutate(
    float* old_pop, float* new_pop, float* fitness,
    int* elite_indices, int elite_count,
    curandState* states, float mutation_rate, int n_palettes
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n_palettes) return;

    curandState localState = states[idx];
    int new_base = idx * 16 * 3;

    // Elite: copy directly
    if (idx < elite_count) {
        int old_idx = elite_indices[idx];
        int old_base = old_idx * 16 * 3;
        for (int i = 0; i < 48; i++) {
            new_pop[new_base + i] = old_pop[old_base + i];
        }
        states[idx] = localState;
        return;
    }

    // Tournament selection for parents
    int p1_idx = elite_indices[(int)(curand_uniform(&localState) * elite_count)];
    int p2_idx = elite_indices[(int)(curand_uniform(&localState) * elite_count)];

    int p1_base = p1_idx * 16 * 3;
    int p2_base = p2_idx * 16 * 3;

    // Crossover and mutate each color
    for (int color = 0; color < 16; color++) {
        ColorRange range = d_ranges[color];
        int color_offset = color * 3;

        if (range.fixed) {
            new_pop[new_base + color_offset + 0] = range.r_min;
            new_pop[new_base + color_offset + 1] = range.g_min;
            new_pop[new_base + color_offset + 2] = range.b_min;
        } else {
            // Uniform crossover
            for (int c = 0; c < 3; c++) {
                float val;
                if (curand_uniform(&localState) < 0.5f) {
                    val = old_pop[p1_base + color_offset + c];
                } else {
                    val = old_pop[p2_base + color_offset + c];
                }

                // Mutation
                if (curand_uniform(&localState) < mutation_rate) {
                    float range_min, range_max;
                    if (c == 0) { range_min = range.r_min; range_max = range.r_max; }
                    else if (c == 1) { range_min = range.g_min; range_max = range.g_max; }
                    else { range_min = range.b_min; range_max = range.b_max; }

                    // Gaussian mutation
                    float range_size = range_max - range_min;
                    val += curand_normal(&localState) * range_size * 0.1f;

                    // Clamp to range
                    if (val < range_min) val = range_min;
                    if (val > range_max) val = range_max;
                }

                new_pop[new_base + color_offset + c] = val;
            }
        }
    }

    states[idx] = localState;
}

// =============================================================================
// Host Functions
// =============================================================================

float h_linearize(float c) {
    float c_srgb = c / 255.0f;
    if (c_srgb <= 0.04045f) return c_srgb / 12.92f;
    return powf((c_srgb + 0.055f) / 1.055f, 2.4f);
}

float h_luminance(float r, float g, float b) {
    return 0.2126f * h_linearize(r) + 0.7152f * h_linearize(g) + 0.0722f * h_linearize(b);
}

float h_contrast_ratio(float r1, float g1, float b1, float r2, float g2, float b2) {
    float l1 = h_luminance(r1, g1, b1);
    float l2 = h_luminance(r2, g2, b2);
    if (l1 > l2) return (l1 + 0.05f) / (l2 + 0.05f);
    return (l2 + 0.05f) / (l1 + 0.05f);
}

// Host-side OKLCH conversion
void h_rgb_to_oklch(float r, float g, float b, float* L, float* C, float* H) {
    float lr = h_linearize(r);
    float lg = h_linearize(g);
    float lb = h_linearize(b);

    float l = 0.4122214708f * lr + 0.5363325363f * lg + 0.0514459929f * lb;
    float m = 0.2119034982f * lr + 0.6806995451f * lg + 0.1073969566f * lb;
    float s = 0.0883024619f * lr + 0.2817188376f * lg + 0.6299787005f * lb;

    float l_ = cbrtf(l);
    float m_ = cbrtf(m);
    float s_ = cbrtf(s);

    *L = 0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_;
    float ok_a = 1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_;
    float ok_b = 0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_;

    *C = sqrtf(ok_a * ok_a + ok_b * ok_b);
    *H = atan2f(ok_b, ok_a) * 180.0f / 3.14159265f;
    if (*H < 0) *H += 360.0f;
}

float h_hue_distance(float h1, float h2) {
    float diff = fabsf(h1 - h2);
    if (diff > 180.0f) diff = 360.0f - diff;
    return diff;
}

// Color code for contrast ratio: red=bad, yellow=ok, green=AA
const char* contrast_color(float cr) {
    if (cr >= 4.5f) return "\033[32m";  // Green for AA
    if (cr >= 3.0f) return "\033[33m";  // Yellow for OK
    return "\033[31m";                   // Red for BAD
}

void print_color_demo(float* palette) {
    const char* names[] = {
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "br.black", "br.red", "br.green", "br.yellow", "br.blue", "br.magenta", "br.cyan", "br.white"
    };

    // Extract key background colors
    int black_r = (int)palette[BLACK * 3 + 0];
    int black_g = (int)palette[BLACK * 3 + 1];
    int black_b = (int)palette[BLACK * 3 + 2];

    int blue_r = (int)palette[BLUE * 3 + 0];
    int blue_g = (int)palette[BLUE * 3 + 1];
    int blue_b = (int)palette[BLUE * 3 + 2];

    int cyan_r = (int)palette[CYAN * 3 + 0];
    int cyan_g = (int)palette[CYAN * 3 + 1];
    int cyan_b = (int)palette[CYAN * 3 + 2];

    printf("\n");
    printf("══════════════════════════════════════════════════════════════════════════════\n");
    printf("                              COLOR PALETTE RESULTS\n");
    printf("══════════════════════════════════════════════════════════════════════════════\n\n");

    // Main palette table with contrast on black, blue, cyan
    printf("Optimized Palette:\n");
    printf("════════════════════════════════════════════════════════════════════════════\n");
    printf("   #  %-10s  %-7s  %-4s  %-10s  %-10s  %-10s\n",
           "Name", "Hex", "Swch", "on Black", "on Blue", "on Cyan");
    printf("────────────────────────────────────────────────────────────────────────────\n");

    for (int i = 0; i < 16; i++) {
        int r = (int)palette[i * 3 + 0];
        int g = (int)palette[i * 3 + 1];
        int b = (int)palette[i * 3 + 2];

        float cr_black = h_contrast_ratio(r, g, b, black_r, black_g, black_b);
        float cr_blue = h_contrast_ratio(r, g, b, blue_r, blue_g, blue_b);
        float cr_cyan = h_contrast_ratio(r, g, b, cyan_r, cyan_g, cyan_b);

        // Number, name, hex, swatch
        printf("  %2d  %-10s  #%02x%02x%02x  \033[48;2;%d;%d;%dm    \033[0m  ",
               i, names[i], r, g, b, r, g, b);

        // On black: sample + colored contrast
        if (i == BLACK) {
            printf("----------");
        } else {
            printf("\033[38;2;%d;%d;%d;48;2;%d;%d;%dm %2d \033[0m %s%5.2f\033[0m",
                   r, g, b, black_r, black_g, black_b, i,
                   contrast_color(cr_black), cr_black);
        }
        printf("  ");

        // On blue
        if (i == BLUE) {
            printf("----------");
        } else {
            printf("\033[38;2;%d;%d;%d;48;2;%d;%d;%dm %2d \033[0m %s%5.2f\033[0m",
                   r, g, b, blue_r, blue_g, blue_b, i,
                   contrast_color(cr_blue), cr_blue);
        }
        printf("  ");

        // On cyan
        if (i == CYAN) {
            printf("----------");
        } else {
            printf("\033[38;2;%d;%d;%d;48;2;%d;%d;%dm %2d \033[0m %s%5.2f\033[0m",
                   r, g, b, cyan_r, cyan_g, cyan_b, i,
                   contrast_color(cr_cyan), cr_cyan);
        }

        printf("\n");
    }

    printf("════════════════════════════════════════════════════════════════════════════\n");
    printf("Legend: \033[32m>=4.5 AA\033[0m  \033[33m>=3.0 OK\033[0m  \033[31m<3.0 BAD\033[0m\n");

    // Constraint check summary
    printf("\nConstraint Check:\n");
    printf("────────────────────────────────────────────────────────────────\n");

    // Base colors on black (with per-color minimums)
    printf("Base colors (1-6) on black (per-color min, max=%.1f):\n", MAX_BASE_ON_BLACK);
    for (int i = 1; i <= 6; i++) {
        int r = (int)palette[i * 3 + 0];
        int g = (int)palette[i * 3 + 1];
        int b = (int)palette[i * 3 + 2];
        float cr = h_contrast_ratio(r, g, b, black_r, black_g, black_b);
        float min_cr = h_min_contrast[i - 1];

        const char* status;
        if (cr >= min_cr && cr <= MAX_BASE_ON_BLACK) {
            status = "\033[32m✓\033[0m";
        } else if (cr < min_cr) {
            status = "\033[31m✗ too dark\033[0m";
        } else {
            status = "\033[33m✗ too bright\033[0m";
        }
        printf("  %-10s %5.2f:1 (min %.1f)  %s\n", names[i], cr, min_cr, status);
    }

    // Bright on regular
    printf("\nBright on Regular (target: >= %.1f):\n", MIN_BRIGHT_ON_REGULAR);
    for (int i = 1; i <= 6; i++) {
        int reg_r = (int)palette[i * 3 + 0];
        int reg_g = (int)palette[i * 3 + 1];
        int reg_b = (int)palette[i * 3 + 2];
        int brt_r = (int)palette[(i + 8) * 3 + 0];
        int brt_g = (int)palette[(i + 8) * 3 + 1];
        int brt_b = (int)palette[(i + 8) * 3 + 2];

        float cr = h_contrast_ratio(brt_r, brt_g, brt_b, reg_r, reg_g, reg_b);

        printf("  br.%-7s on %-7s: \033[38;2;%d;%d;%d;48;2;%d;%d;%dm Sample \033[0m %s%5.2f:1\033[0m  %s\n",
               names[i], names[i],
               brt_r, brt_g, brt_b, reg_r, reg_g, reg_b,
               contrast_color(cr), cr,
               cr >= MIN_BRIGHT_ON_REGULAR ? "\033[32m✓\033[0m" : "\033[31m✗\033[0m");
    }

    // Cyan on blue - disabled (only MC cursor uses this)

    // 16x16 sample matrix
    printf("\nSample Matrix (FG on BG) - each cell shows fg color # on bg color:\n");
    printf("FG\\BG");
    for (int bg = 0; bg < 16; bg++) {
        printf(" %2d ", bg);
    }
    printf("\n");

    for (int fg = 0; fg < 16; fg++) {
        printf("  %2d ", fg);
        int fg_r = (int)palette[fg * 3 + 0];
        int fg_g = (int)palette[fg * 3 + 1];
        int fg_b = (int)palette[fg * 3 + 2];

        for (int bg = 0; bg < 16; bg++) {
            int bg_r = (int)palette[bg * 3 + 0];
            int bg_g = (int)palette[bg * 3 + 1];
            int bg_b = (int)palette[bg * 3 + 2];

            printf("\033[38;2;%d;%d;%d;48;2;%d;%d;%dm %2d \033[0m",
                   fg_r, fg_g, fg_b, bg_r, bg_g, bg_b, fg);
        }
        printf("\n");
    }

    // OKLCH Analysis
    printf("\nOKLCH Analysis (Perceptually Uniform Color Space):\n");
    printf("────────────────────────────────────────────────────────────────\n");
    printf("%-12s  L (light)  C (chroma)  H (hue°)\n", "Color");
    printf("────────────────────────────────────────────────────────────────\n");

    float base_hues[6];
    float base_chromas[6];
    for (int i = 1; i <= 6; i++) {
        int r = (int)palette[i * 3 + 0];
        int g = (int)palette[i * 3 + 1];
        int b = (int)palette[i * 3 + 2];
        float L, C, H;
        h_rgb_to_oklch(r, g, b, &L, &C, &H);
        base_hues[i-1] = H;
        base_chromas[i-1] = C;
        printf("%-12s  %5.3f      %5.3f       %6.1f°\n", names[i], L, C, H);
    }

    // Hue spacing analysis
    printf("\nHue Spacing (ideal: 60° between colors):\n");
    printf("────────────────────────────────────────────────────────────────\n");
    float min_hue_dist = 360.0f;
    const char* min_pair_a = "";
    const char* min_pair_b = "";
    for (int i = 0; i < 6; i++) {
        for (int j = i + 1; j < 6; j++) {
            float hdist = h_hue_distance(base_hues[i], base_hues[j]);
            if (hdist < min_hue_dist) {
                min_hue_dist = hdist;
                min_pair_a = names[i + 1];
                min_pair_b = names[j + 1];
            }
        }
    }
    printf("  Minimum hue distance: %.1f° (between %s and %s)\n", min_hue_dist, min_pair_a, min_pair_b);
    if (min_hue_dist >= 50.0f) {
        printf("  Status: \033[32m✓ Good spacing\033[0m\n");
    } else if (min_hue_dist >= 30.0f) {
        printf("  Status: \033[33m~ Acceptable spacing\033[0m\n");
    } else {
        printf("  Status: \033[31m✗ Colors too close in hue\033[0m\n");
    }

    // Bright color hue matching
    printf("\nBright/Base Hue Matching (bright should match base hue):\n");
    printf("────────────────────────────────────────────────────────────────\n");
    for (int i = 1; i <= 6; i++) {
        float L1, C1, H1, L2, C2, H2;
        h_rgb_to_oklch(palette[i * 3 + 0], palette[i * 3 + 1], palette[i * 3 + 2], &L1, &C1, &H1);
        h_rgb_to_oklch(palette[(i + 8) * 3 + 0], palette[(i + 8) * 3 + 1], palette[(i + 8) * 3 + 2], &L2, &C2, &H2);
        float hdist = h_hue_distance(H1, H2);
        printf("  %-10s → br.%-7s: ΔH=%5.1f°  %s\n",
               names[i], names[i], hdist,
               hdist <= 30.0f ? "\033[32m✓\033[0m" : "\033[31m✗ hue drift\033[0m");
    }

    // Ghostty config format (just palette)
    printf("\nGhostty palette:\n");
    printf("────────────────────────────────────────────────────────────────\n");
    for (int i = 0; i < 16; i++) {
        int r = (int)palette[i * 3 + 0];
        int g = (int)palette[i * 3 + 1];
        int b = (int)palette[i * 3 + 2];
        printf("palette = %d=#%02x%02x%02x\n", i, r, g, b);
    }

    // Full Ghostty theme file
    printf("\n");
    printf("════════════════════════════════════════════════════════════════════════════\n");
    printf("                         FULL GHOSTTY THEME FILE\n");
    printf("════════════════════════════════════════════════════════════════════════════\n");
    printf("Save this to: ~/.config/ghostty/themes/WCAG-Optimized\n");
    printf("Then set: theme = WCAG-Optimized\n");
    printf("────────────────────────────────────────────────────────────────────────────\n");

    // Get specific colors for theme properties
    int bg_r = (int)palette[BLACK * 3 + 0];
    int bg_g = (int)palette[BLACK * 3 + 1];
    int bg_b = (int)palette[BLACK * 3 + 2];

    int fg_r = (int)palette[WHITE * 3 + 0];
    int fg_g = (int)palette[WHITE * 3 + 1];
    int fg_b = (int)palette[WHITE * 3 + 2];

    int sel_bg_r = (int)palette[BLUE * 3 + 0];
    int sel_bg_g = (int)palette[BLUE * 3 + 1];
    int sel_bg_b = (int)palette[BLUE * 3 + 2];

    // Cursor: use bright yellow or orange for visibility
    int cursor_r = (int)palette[BR_YELLOW * 3 + 0];
    int cursor_g = (int)palette[BR_YELLOW * 3 + 1];
    int cursor_b = (int)palette[BR_YELLOW * 3 + 2];

    printf("# WCAG-Optimized Theme\n");
    printf("# Generated by CUDA Color Optimizer v2.5\n");
    printf("# Constraints: Red>=5.5, Green>=4.5, others>=3.5 on black\n");
    printf("#\n");
    printf("\n");

    // Palette
    for (int i = 0; i < 16; i++) {
        int r = (int)palette[i * 3 + 0];
        int g = (int)palette[i * 3 + 1];
        int b = (int)palette[i * 3 + 2];
        printf("palette = %d=#%02x%02x%02x\n", i, r, g, b);
    }

    printf("\n");
    printf("background = #%02x%02x%02x\n", bg_r, bg_g, bg_b);
    printf("foreground = #%02x%02x%02x\n", fg_r, fg_g, fg_b);
    printf("\n");
    printf("cursor-color = #%02x%02x%02x\n", cursor_r, cursor_g, cursor_b);
    printf("cursor-text = #%02x%02x%02x\n", bg_r, bg_g, bg_b);
    printf("\n");
    printf("selection-background = #%02x%02x%02x\n", sel_bg_r, sel_bg_g, sel_bg_b);
    printf("selection-foreground = #ffffff\n");

    printf("────────────────────────────────────────────────────────────────────────────\n");
    printf("\n══════════════════════════════════════════════════════════════════════════════\n");
}

// =============================================================================
// Main
// =============================================================================

// Write theme to file
void write_theme_file(float* palette, const char* filepath) {
    FILE* f = fopen(filepath, "w");
    if (!f) {
        printf("Error: Could not write to %s\n", filepath);
        return;
    }

    fprintf(f, "# WCAG-Optimized Theme\n");
    fprintf(f, "# Generated by CUDA Color Optimizer v2.5\n");
    fprintf(f, "# Constraints: Red>=5.5, Green>=4.5, others>=3.5 on black\n");
    fprintf(f, "#\n\n");

    // Palette
    for (int i = 0; i < 16; i++) {
        int r = (int)palette[i * 3 + 0];
        int g = (int)palette[i * 3 + 1];
        int b = (int)palette[i * 3 + 2];
        fprintf(f, "palette = %d=#%02x%02x%02x\n", i, r, g, b);
    }

    // Background/foreground
    int bg_r = (int)palette[BLACK * 3 + 0];
    int bg_g = (int)palette[BLACK * 3 + 1];
    int bg_b = (int)palette[BLACK * 3 + 2];
    int fg_r = (int)palette[WHITE * 3 + 0];
    int fg_g = (int)palette[WHITE * 3 + 1];
    int fg_b = (int)palette[WHITE * 3 + 2];

    fprintf(f, "\nbackground = #%02x%02x%02x\n", bg_r, bg_g, bg_b);
    fprintf(f, "foreground = #%02x%02x%02x\n", fg_r, fg_g, fg_b);

    // Cursor (bright yellow)
    int cursor_r = (int)palette[BR_YELLOW * 3 + 0];
    int cursor_g = (int)palette[BR_YELLOW * 3 + 1];
    int cursor_b = (int)palette[BR_YELLOW * 3 + 2];
    fprintf(f, "\ncursor-color = #%02x%02x%02x\n", cursor_r, cursor_g, cursor_b);
    fprintf(f, "cursor-text = #%02x%02x%02x\n", bg_r, bg_g, bg_b);

    // Selection (blue background)
    int sel_r = (int)palette[BLUE * 3 + 0];
    int sel_g = (int)palette[BLUE * 3 + 1];
    int sel_b = (int)palette[BLUE * 3 + 2];
    fprintf(f, "\nselection-background = #%02x%02x%02x\n", sel_r, sel_g, sel_b);
    fprintf(f, "selection-foreground = #ffffff\n");

    fclose(f);
    printf("\n✓ Theme written to: %s\n", filepath);
}

int main(int argc, char** argv) {
    int population_size = 200000;
    int generations = 5000;
    float mutation_rate = 0.15f;
    float elite_ratio = 0.1f;
    const char* output_file = NULL;

    // Parse args
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--population") == 0 || strcmp(argv[i], "-p") == 0) {
            population_size = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--generations") == 0 || strcmp(argv[i], "-g") == 0) {
            generations = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--mutation") == 0 || strcmp(argv[i], "-m") == 0) {
            mutation_rate = atof(argv[++i]);
        } else if (strcmp(argv[i], "--output") == 0 || strcmp(argv[i], "-o") == 0) {
            output_file = argv[++i];
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("CUDA Color Palette Optimizer v2.5 (Golden yellow, brighter red)\n");
            printf("Usage: %s [options]\n", argv[0]);
            printf("  -p, --population N   Population size (default: 200000)\n");
            printf("  -g, --generations N  Number of generations (default: 5000)\n");
            printf("  -m, --mutation F     Mutation rate (default: 0.15)\n");
            printf("  -o, --output FILE    Write theme to file\n");
            return 0;
        }
    }

    int elite_count = (int)(population_size * elite_ratio);

    printf("╔══════════════════════════════════════════════════════════════════════════════╗\n");
    printf("║        CUDA Color Palette Optimizer v2.5 (Golden yellow, brighter red)      ║\n");
    printf("╚══════════════════════════════════════════════════════════════════════════════╝\n\n");

    printf("Parameters:\n");
    printf("  Population: %d\n", population_size);
    printf("  Generations: %d\n", generations);
    printf("  Mutation rate: %.2f (adaptive)\n", mutation_rate);
    printf("  Elite ratio: %.2f\n\n", elite_ratio);

    printf("Fixed colors:\n");
    printf("  Black:    #000000\n");
    printf("  White:    #bfbfbf\n");
    printf("  Br.Black: #404040\n");
    printf("  Br.White: #ffffff\n\n");

    printf("Constraints:\n");
    printf("  1. Base colors (1-6) on black: per-color min <= CR <= %.1f\n", MAX_BASE_ON_BLACK);
    printf("     Red: >= %.1f, Green: >= %.1f, Yellow: >= %.1f\n",
           h_min_contrast[0], h_min_contrast[1], h_min_contrast[2]);
    printf("     Blue: >= %.1f, Magenta: >= %.1f, Cyan: >= %.1f\n",
           h_min_contrast[3], h_min_contrast[4], h_min_contrast[5]);
    printf("  2. Bright on regular (br.X on X): CR >= %.1f\n", MIN_BRIGHT_ON_REGULAR);
    printf("  3. Cyan on blue: DISABLED\n\n");

    // Print color ranges
    printf("Color ranges:\n");
    const char* names[] = {
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "br.black", "br.red", "br.green", "br.yellow", "br.blue", "br.magenta", "br.cyan", "br.white"
    };
    for (int i = 0; i < 16; i++) {
        const ColorRange& r = color_ranges[i];
        if (r.fixed) {
            printf("  %-12s (fixed #%02x%02x%02x)\n", names[i],
                   (int)r.r_min, (int)r.g_min, (int)r.b_min);
        } else {
            printf("  %-12s R:%3.0f-%-3.0f  G:%3.0f-%-3.0f  B:%3.0f-%-3.0f\n",
                   names[i], r.r_min, r.r_max, r.g_min, r.g_max, r.b_min, r.b_max);
        }
    }
    printf("\n");

    // Check CUDA
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);
    if (deviceCount == 0) {
        printf("No CUDA devices found!\n");
        return 1;
    }

    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    printf("Using GPU: %s\n\n", prop.name);

    // Copy color ranges to device
    cudaMemcpyToSymbol(d_ranges, color_ranges, sizeof(color_ranges));

    // Allocate memory
    size_t palette_size = population_size * 16 * 3 * sizeof(float);
    float *d_pop1, *d_pop2, *d_fitness;
    curandState* d_states;
    int* d_elite_indices;

    cudaMalloc(&d_pop1, palette_size);
    cudaMalloc(&d_pop2, palette_size);
    cudaMalloc(&d_fitness, population_size * sizeof(float));
    cudaMalloc(&d_states, population_size * sizeof(curandState));
    cudaMalloc(&d_elite_indices, elite_count * sizeof(int));

    // Initialize
    int blockSize = 256;
    int numBlocks = (population_size + blockSize - 1) / blockSize;

    printf("Initializing population...\n");
    init_curand<<<numBlocks, blockSize>>>(d_states, time(NULL), population_size);
    init_population<<<numBlocks, blockSize>>>(d_pop1, d_states, population_size);
    cudaDeviceSynchronize();

    // Host arrays for elite selection
    std::vector<float> h_fitness(population_size);
    std::vector<int> h_elite_indices(elite_count);

    float best_fitness = -1e9f;
    int stagnant_generations = 0;
    float current_mutation = mutation_rate;

    printf("Starting evolution...\n\n");

    for (int gen = 0; gen < generations; gen++) {
        // Evaluate fitness
        evaluate_fitness<<<numBlocks, blockSize>>>(d_pop1, d_fitness, population_size);
        cudaDeviceSynchronize();

        // Copy fitness to host
        cudaMemcpy(h_fitness.data(), d_fitness, population_size * sizeof(float), cudaMemcpyDeviceToHost);

        // Find elite indices
        std::vector<int> indices(population_size);
        for (int i = 0; i < population_size; i++) indices[i] = i;

        std::partial_sort(indices.begin(), indices.begin() + elite_count, indices.end(),
            [&h_fitness](int a, int b) { return h_fitness[a] > h_fitness[b]; });

        for (int i = 0; i < elite_count; i++) {
            h_elite_indices[i] = indices[i];
        }

        float gen_best = h_fitness[indices[0]];

        // Adaptive mutation
        if (gen_best > best_fitness) {
            best_fitness = gen_best;
            stagnant_generations = 0;
            current_mutation = mutation_rate;
        } else {
            stagnant_generations++;
            if (stagnant_generations > 100) {
                current_mutation = fminf(0.5f, current_mutation * 1.01f);
            }
        }

        // Progress output
        if (gen % 500 == 0 || gen == generations - 1) {
            printf("Gen %5d: best=%.2f, avg=%.2f, mutation=%.3f\n",
                   gen, gen_best,
                   std::accumulate(h_fitness.begin(), h_fitness.end(), 0.0f) / population_size,
                   current_mutation);
        }

        if (gen < generations - 1) {
            // Copy elite indices to device
            cudaMemcpy(d_elite_indices, h_elite_indices.data(), elite_count * sizeof(int), cudaMemcpyHostToDevice);

            // Crossover and mutation
            crossover_and_mutate<<<numBlocks, blockSize>>>(
                d_pop1, d_pop2, d_fitness, d_elite_indices, elite_count,
                d_states, current_mutation, population_size
            );
            cudaDeviceSynchronize();

            // Swap populations
            std::swap(d_pop1, d_pop2);
        }
    }

    // Get best palette
    std::vector<float> h_palette(16 * 3);
    int best_idx = h_elite_indices[0];
    cudaMemcpy(h_palette.data(), d_pop1 + best_idx * 16 * 3, 16 * 3 * sizeof(float), cudaMemcpyDeviceToHost);

    // Print results
    print_color_demo(h_palette.data());

    // Write theme file if requested
    if (output_file) {
        write_theme_file(h_palette.data(), output_file);
    }

    // Cleanup
    cudaFree(d_pop1);
    cudaFree(d_pop2);
    cudaFree(d_fitness);
    cudaFree(d_states);
    cudaFree(d_elite_indices);

    return 0;
}
