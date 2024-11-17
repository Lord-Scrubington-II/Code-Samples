// Upgrade NOTE: replaced '_CameraToWorld' with 'unity_CameraToWorld'

// Upgrade NOTE: commented out 'float4x4 _CameraToWorld', a built-in variable

Shader "Hidden/NewImageEffectShader"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        // No culling or depth
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"

            // float4x4 _CameraToWorld; // nvm, it is already accessible in this fragment shader
            float4x4 _CameraInverseProjection;

            // - BEGIN: Ray Generation  ----------------------------------------------------------
            struct Ray
            {
	            float3 origin;
	            float3 direction;
            };

            Ray NewRay(float3 origin, float3 direction)
            {
	            Ray ray;
	            ray.origin = origin;
	            ray.direction = direction;
	            return ray;
            }

            // Given a Vector2 in normalized device coordinates [-1, 1], generate a primary ray from the camera
            Ray CameraRayGen(float2 ndc_xy) 
            {
	            // As before, we want ray origin and direction in world space.
	
	            // Extract camera aperture transform
                float3 origin = mul(unity_CameraToWorld, float4(0.0f, 0.0f, 0.0f, 1.0f)).xyz;

	            // invert the projection of camera-space direction --> ndc-uv coordinates...
                float3 direction = mul(_CameraInverseProjection, float4(ndc_xy, 0.0f, 1.0f)).xyz;

	            // ...then, transform to world space and normalize.
                direction = normalize(
                    mul(unity_CameraToWorld, float4(direction, 0.0f)).xyz
                );
	
                return NewRay(origin, direction);
            }
            // - END: Ray Generation ----------------------------------------------------------

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
                Ray cam_ray : TEXCOORD1;
            };

            v2f vert (appdata v)
            {
                v2f output;
                output.vertex = UnityObjectToClipPos(v.vertex);
                output.uv = v.uv;

                float2 ndc_xy = float2(v.uv * 2.0f - 1.0f);
                
                // BEGIN ray generation
                float3 origin = _WorldSpaceCameraPos;

                // invert the projection of camera-space direction --> ndc-uv coordinates...
                float3 direction = mul(_CameraInverseProjection, float4(ndc_xy, 0.0f, -1.0f)).xyz;
	            // ...then, transform to world space. NOTE: Not yet normalized, as we need the length of this vector!
                direction = mul(unity_CameraToWorld, float4(direction, 0.0f)).xyz;
                output.cam_ray = NewRay(origin, direction);
                // END ray generation

                return output;
            }

            sampler2D _MainTex;
            sampler2D _CameraDepthTexture;

            // BEGIN: values set & passed from inspector -------------------------------------------------------

            float3 _SunDir; // direction of the sunlight
            float3 _SunColour; // colour of the sunlight

            float3 _BoxMax; // Max world space point (largest 2-norm) of the cloud's bounding box
            float3 _BoxMin; // Min world space point (smallest 2-norm) of the cloud's bounding box

            // noise sampling
            float3 _CloudsOffset; // should allow the cloud to "move" in the box
            float _CloudsScale; // used to manipulate the mapping from texture to world space
            float4 _ShapeNoiseWeights; // used to form a linear combination between the shape noise channels

            float3 _DetailOffset; // allows details to be controlled independently of the shape
            float _DetailScale; // used to manipulate the mapping from detail texture to world space
            float3 _DetailNoiseWeights; // used to form a linear combination between the shape noise channels
            float _DetailNoiseOverallWeight; // controls overall importance of detail noise

            int _NumSamples; // controls # of steps taken when marching the camera ray
            int _StepsToLight; // controls # of steps taken when marching towards the sun
            float _BlueNoiseStrength; // controls how much to jitter ray starting pos

            // lighting vars
            float _DensityReadOffset; // to be subtracted from the density reading
            float _DensityMult; // just a multiplier for the density reading, should be used to manipulate cloud darkness
            float _AbsorptionCoeff; // used to manipulate absorption from Beer's law along primary ray. Increasing this makes clouds darker.
            float _AbsorptionCoeffSecondary; // used to manipulate absorption from Beer's law along secondary rays. Increasing this makes clouds self-shadow more.
            float _DarknessThreshold; // minimum light transmittance along the secondary rays
            float _ScatteringTerm; // the scattering term of the Henyey-Greenstein phase function.
            float _ScatteringCoeff; // for controlling the forward scattering

            // END: values set & passed from inspector ---------------------------------------------------------


            // - BEGIN: Textures passed from C# ----------------------------------------------------------------
            // _Worley {Texture3D<float4>}: This is a 3D Worley noise texture (currently) produced by a 
            //      3rd-party noise generator. There should be 3 levels of increasing granularity stored in the
            //      red, green, and blue channels of the noise, with _Worley.r being the least granular.
            //      Used to create large, billowy cloud shapes.
            // _Perlin {Texture3D<float4>}: This is a 3D Perlin noise texture (currently) produced by a 
            //      3rd-party noise generator. Used to add fine details to the edge of the cloud shapes.
            // _BlueNoise {Texture3D<float4>}: This is a 2D Blue noise texture taken from http://momentsingraphics.de/Media/BlueNoise/BlueNoise470.png.
            //      Used to combat banding from quadrature.
            // sampler_Worley {SamplerState}: Used to sample from the Worley noise texture.
            // sampler_Perlin {SamplerState}: Used to sample from the Perlin noise texture.
            // sampler_Blue {SamplerState}: Used to sample from the Blue noise texture.
            Texture3D<float4> _Worley; 
            Texture3D<float4> _Perlin;
            Texture2D<float4> _BlueNoise;
            SamplerState sampler_Worley;
            SamplerState sampler_Perlin;
            SamplerState sampler_BlueNoise;
            // - END: Textures passed from C# ------------------------------------------------------------------
            
            // Constants
            static float PI = 3.141592;
            static float INV_PI = 0.31831;

            // Ray-box intersection
            bool BoxIntersects(
                Ray ray, 
                float3 box_min, 
                float3 box_max, 
                inout float dist_to_box, 
                inout float dist_inside_box
            ) {
                // Adapted from Majercik et al. 2018 "A Ray-Box Intersection Algorithm and Efficient Dynamic Voxel Rendering"
                float3 v0 = (box_min - ray.origin) * (1.0f / ray.direction);
                float3 v1 = (box_max - ray.origin) * (1.0f / ray.direction);
                float3 v_max = max(v0, v1);
                float3 v_min = min(v0, v1);
                
                // now, we want to know if the max component of t_min
                // is greater than the min component of t_max. If so, then no intersection occurred.
                float dist_near = max(max(v_min.x, v_min.y), v_min.z);
                float dist_far = min(min(v_max.x, v_max.y), v_max.z);

                dist_to_box = max(0.0f, dist_near); // if inside box, will be 0
                dist_inside_box = max(0, dist_far - dist_to_box); // shouldn't really ever be negative unless facing away from the box

                if (dist_near > dist_far) {
                    return false;
                } return true;
            }

            // - BEGIN: Light Scattering Model -----------------------------------------------------------
            
            // - FUNCTION -
            // Henyey_Greenstein --> float: This implements the Henyey-Greenstein Phase Function.
            // - RETURNS -
            //  A coefficient which should be multiplied with the final light energy.
            // - PARAMS - 
            //  float cosTheta: The cosine of the angle between the lighting direction and viewing direction
            //  float g: the scattering term. g must be in the range [-1, 1] where negative values correspond to
            //          back scattering and positive values correspond to forward scattering.
            float Henyey_Greenstein(float cosTheta, float g) {
                float g_sqrd = g * g;
                float denom = 1.0f + g_sqrd - 2.0f * g * cosTheta;
                float phase_boost_coeff = 0.25 * INV_PI * (1.0f - g_sqrd) / (denom * sqrt(denom));
                return phase_boost_coeff;
            }

            // - FUNCTION -
            // Beer --> float: This implements Beer's absorption law.
            // - RETURNS - 
            // A transmittance coefficient which should be multiplied with the final light energy.
            // - PARAMS - 
            //  float density: The measured density over the path towards the light
            //  float atten_coeff: A (mostly artistic) attenuation coefficient which can be used 
            //          to manipulate the absorption.
            float Beer(float density, float atten_coeff) {
                float transmittance = exp(-density * atten_coeff);
                return transmittance;
            }
            // - END: Light Scattering Model -------------------------------------------------------------

            float NoiseSampleDensitySimple(float3 pos) {
                // Experimentally, these seem like good coefficients for the control variables
                float3 xyz = pos * _CloudsScale * 0.001 + _CloudsOffset * 0.1;
                float4 worley_read = _Worley.SampleLevel(sampler_Worley, xyz, 0);
                float cloud_density = (worley_read.r - _DensityReadOffset * 0.1f) * _DensityMult;
                return cloud_density;
            }

            float NoiseSampleDensity(float3 pos) {
                // the offset and scale of the shape and noise texture readings should be independent
                // Experimentally, these seem like good coefficients for the control variables
                const float scale_coeff = 0.0001;
                const float position_offset_coeff = 0.01;
                const float density_read_coeff = 0.01;
                const float detail_read_coeff = 0.1;

                float3 xyz = pos * _CloudsScale * scale_coeff;

                // we want to now calculate some reasonable falloff at all the edges of the container
                // so that they don't appear flattened against the edges of the bounding box.
                // Adapted from Sebastian Lague's code
                const float container_edge_fade_dist = 30;
                float dist_edges_x = min(container_edge_fade_dist, abs(min(pos.x - _BoxMin.x, _BoxMax.x - pos.x)));
                float dist_edges_y = min(container_edge_fade_dist, abs(min(pos.y - _BoxMin.y, _BoxMax.y - pos.y)));
                float dist_edges_z = min(container_edge_fade_dist, abs(min(pos.z - _BoxMin.z, _BoxMax.z - pos.z)));
                float edge_weight = min(min(dist_edges_x, dist_edges_y), dist_edges_z) / container_edge_fade_dist;
                // float edge_weight = min(dist_edges_x, dist_edges_z) / container_edge_fade_dist;

                // shape noise read position
                float3 worley_xyz = xyz + _CloudsOffset * position_offset_coeff;
                float4 worley_read = _Worley.SampleLevel(sampler_Worley, worley_xyz, 0);
                
                // now, we want to take the normalized shape noise weights.
                // must divide by the VECTOR 1-NORM because we want the weights to sum to 1.
                float4 cloud_shape_weights_normalized = _ShapeNoiseWeights / (_ShapeNoiseWeights.x + _ShapeNoiseWeights.y + _ShapeNoiseWeights.z + _ShapeNoiseWeights.w);

                // now, combine the noise weights
                float cloud_density = (
                    dot(worley_read, cloud_shape_weights_normalized)
                    - _DensityReadOffset * 0.1
                ) * edge_weight;

                // for nonzero shape density readings, we will want to sample the detail noise.
                // the detail noise will be SUBTRACTED from the shape to produce the "wispy clouds" effect
                // that we are looking for.
                if (cloud_density > 0.0) {
                    // sampling is almost exactly the same as with the shape noise texture
                    float3 perlin_xyz = xyz * _DetailScale + _DetailOffset * position_offset_coeff;
                    float4 perlin_read = _Perlin.SampleLevel(sampler_Perlin, perlin_xyz, 0);
                    float3 cloud_detail_weights_normalized = _DetailNoiseWeights / (_DetailNoiseWeights.x + _DetailNoiseWeights.y + _DetailNoiseWeights.z);

                    // combine the noise weights
                    float detail_density = dot(perlin_read, cloud_detail_weights_normalized);

                    // now, we want to subtract the detail noise. Greater weight should be given to areas with lesser density
                    // so that more is subtracted from the edges instead of the centre. Partialyl adapted from Sebastian Lague's code.
                    float detail_density_weight = 1.0f - cloud_density;
                    detail_density_weight = detail_density_weight * detail_density_weight;
                    cloud_density = cloud_density - detail_density * detail_density_weight * detail_read_coeff * _DetailNoiseOverallWeight;
                }
                return cloud_density * _DensityMult * density_read_coeff;
            }

            // This function marches a light ray towards the sun to accumulate density
            // and returns the transmittance over the light ray.
            float LightMarch(float3 start_point) {
                Ray to_light = NewRay(start_point, normalize(-1.0f * _SunDir));

                float dist_to_box;  // should be 0
                float dist_in_box;
                BoxIntersects(to_light, _BoxMin, _BoxMax, dist_to_box, dist_in_box);

                float density_measured = 0.0f;
                float3 density_read_pos = start_point;
                float step_size = dist_in_box / (float)_StepsToLight;
            
                // praise the sun \[T]/
                for (int i = 0; i < _StepsToLight; i++) {
                    // effectively, what we are doing is solving a line integral
                    // over the noise density function. Hence, we will want to multiply
                    // by the step size to get an estimate over quadrature.
                    density_measured += max(NoiseSampleDensity(density_read_pos), 0.0f) * step_size;
                    density_read_pos += to_light.direction * step_size;
                }

                // return density_measured;
                float transmittance = Beer(density_measured, _AbsorptionCoeffSecondary);
                
                // idea of including this darkness threshold comes from Sebastian Lague's video.
                // allows me to manipulate the darkness of the clouds with greater weight given to denser areas.
                return _DarknessThreshold + (1.0f - _DarknessThreshold) * transmittance;
            }

            fixed4 frag (v2f input) : SV_Target
            {                
                // - BEGIN: Initial Ray Intersection -------------------------------------------------
                float nonlinear_depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, input.uv);
                // float cam_frustum_len = _ProjectionParams.z - _ProjectionParams.y; // far - near 
                float depth = LinearEyeDepth(nonlinear_depth) * length(input.cam_ray.direction); // for some reason, need to multiply by 

                Ray cam_ray = input.cam_ray;
                cam_ray.direction = normalize(cam_ray.direction);

                // cloud container-camera ray intersection t-values
                float dist_to_box; float dist_in_box; 
                bool hit_cloud = BoxIntersects(
                    cam_ray,
                    _BoxMin,
                    _BoxMax,
                    dist_to_box,
                    dist_in_box
                );
                // - END: Initial Ray Intersection ---------------------------------------------------

                // now, we want to find the sample step size
                // and ray entry & exit points
                float step_size = dist_in_box / (float)_NumSamples;
                float3 cloud_entry_point = cam_ray.origin + cam_ray.direction * dist_to_box;
                //float3 cloud_exit_point = cloud_entry_point + cam_ray.direction * dist_in_box;

                // to minimize texture reads, we can jitter only the starting point offset using the blue noise texture.
                float ray_entry_jitter = _BlueNoise.SampleLevel(sampler_BlueNoise, input.uv * _BlueNoiseStrength, 0) * 10 * _BlueNoiseStrength;

                // phase function
                float cosTheta = dot(cam_ray.direction, -_SunDir);
                float phase_coeff = 1.0f + Henyey_Greenstein(cosTheta, _ScatteringTerm) * _ScatteringCoeff;

                float3 sample_point = cloud_entry_point + cam_ray.direction * ray_entry_jitter;
                float density_measured = 0.0f;
                float3 sunlight_transmittance = 0.0f; // start with 0 light energy from scattering and add up contributions from sunbeams
                float occlusion_transmittance = 1.0f; // start with full transmittance and accumulate attenuations
                if (hit_cloud && dist_to_box < depth) { // begin ray march
                    // move sample point along ray by step size for each sample
                    // then, add up the density values and attenuate incoming light
                    // by the transmittance function.
                    float dist_travelled = ray_entry_jitter;
                    while (dist_travelled < dist_in_box) {
                        density_measured = max(NoiseSampleDensity(sample_point), 0.0f);

                        if (density_measured > 0) { // only for nonzero density reads to we want to march towards light
                            // transmittance along secondary ray
                            float source_transmittance = LightMarch(sample_point);
                            sunlight_transmittance += density_measured * step_size * occlusion_transmittance * source_transmittance;

                            // modify transmittance for next point along primary ray (i.e. its energy contribution will be smaller by Beer's law)
                            // this is mathematically equivalent to taking the density path integral first by the laws of exponents
                            occlusion_transmittance *= Beer(density_measured * step_size, _AbsorptionCoeff);

                            // if the transmittance is already very small, we can stop early (diminishing returns)
                            if (occlusion_transmittance < 0.01) {
                                break;
                            }
                        }
                        
                        sample_point = sample_point + cam_ray.direction * step_size;
                        dist_travelled += step_size;
                    }
                }

                // float transmittance = exp(-density_measured);
                // the cloud's colour is the light energy accumulated multiplied by the sun's colour.
                // the denser, the more that the cloud's colour contributes to the pixel.
                float3 cloud_colour = sunlight_transmittance * _SunColour * phase_coeff;
                
                // add attenuated colour of occluded geometry to the colour of the cloud itself to get the
                // final colour for this pixel
                float3 geometry_colour = tex2D(_MainTex, input.uv);
                float3 final_colour = geometry_colour * occlusion_transmittance + cloud_colour;
                return float4(final_colour, 1.0f);
            }
            ENDCG
        }
    }
}
