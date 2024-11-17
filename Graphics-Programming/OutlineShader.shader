Shader "Roystan-Wang/Post Process Outline"
{
	SubShader
	{
		Cull Off ZWrite Off ZTest Always

		Pass
		{
			Name "ContourExtract"
			// Custom post processing effects are written in HLSL blocks,
			// with lots of macros to aid with platform differences.
			// https://github.com/Unity-Technologies/PostProcessing/wiki/Writing-Custom-Effects#shader
			HLSLPROGRAM
			#pragma vertex Vert
			#pragma fragment Frag

			#include "Packages/com.unity.postprocessing/PostProcessing/Shaders/StdLib.hlsl"

			TEXTURE2D_SAMPLER2D(_MainTex, sampler_MainTex);
			// _CameraNormalsTexture contains the view space normals transformed
			// to be in the 0...1 range.
			TEXTURE2D_SAMPLER2D(_CameraNormalsTexture, sampler_CameraNormalsTexture);
			TEXTURE2D_SAMPLER2D(_CameraDepthTexture, sampler_CameraDepthTexture);
		
			// Data pertaining to _MainTex's dimensions.
			// https://docs.unity3d.com/Manual/SL-PropertiesInPrograms.html
			float4 _MainTex_TexelSize;
			float _EdgeFilterScale;
			float _DepthDiffThreshold;
			float _NormalDiffThreshold;

			float _DepthNormalLowerBound;
			float _DepthNormalScale;

			float4 _EdgeColour;

			float4x4 _InvProjectionMatrix;

			struct VertDataModule
			{
				float4 vertex : SV_POSITION;
				float2 texcoord : TEXCOORD0;
				float2 texcoordStereo : TEXCOORD1;
				float3 viewDir : TEXCOORD2;

			#if STEREO_INSTANCING_ENABLED
				uint stereoTargetEyeIndex : SV_RenderTargetArrayIndex;
			#endif
			};

			VertDataModule Vert(AttributesDefault v) // contains the varyings
			{
				VertDataModule vdm;
				vdm.vertex = float4(v.vertex.xy, 0.0, 1.0); // clip space (NDC) ranges from (-1, -1) to (1, 1)
				vdm.texcoord = TransformTriangleVertexToUV(v.vertex.xy);

			#if UNITY_UV_STARTS_AT_TOP
				vdm.texcoord = vdm.texcoord * float2(1.0, -1.0) + float2(0.0, 1.0);
			#endif

				vdm.texcoordStereo = TransformStereoScreenSpaceTex(vdm.texcoord, 1.0);

				// we get the viewing direction by unprojecting the NDC 
				vdm.viewDir = mul(_InvProjectionMatrix, vdm.vertex).xyz;

				return vdm;
			}

			// Combines the top and bottom colours using normal blending.
			// https://en.wikipedia.org/wiki/Blend_modes#Normal_blend_mode
			// This performs the same operation as Blend SrcAlpha OneMinusSrcAlpha.
			float4 alphaBlend(float4 top, float4 bottom)
			{
				float3 colour = (top.rgb * top.a) + (bottom.rgb * (1 - top.a));
				float alpha = top.a + bottom.a * (1 - top.a);

				return float4(colour, alpha);
			}

			float4 Frag(VertDataModule i) : SV_Target
			{
				float halfScaleFloor = floor(_EdgeFilterScale * 0.5);
				float halfScaleCeil = ceil(_EdgeFilterScale * 0.5);

				// From skeleton code
				// Compute the UV of the filter corners based on the edge width defined in C#
				float2 bottomLeftUV = i.texcoord - float2(_MainTex_TexelSize.x, _MainTex_TexelSize.y) * halfScaleFloor;
				float2 topRightUV = i.texcoord + float2(_MainTex_TexelSize.x, _MainTex_TexelSize.y) * halfScaleCeil;
				float2 bottomRightUV = i.texcoord + float2(_MainTex_TexelSize.x * halfScaleCeil, -_MainTex_TexelSize.y * halfScaleFloor);
				float2 topLeftUV = i.texcoord + float2(-_MainTex_TexelSize.x * halfScaleFloor, _MainTex_TexelSize.y * halfScaleCeil);
				float4 colour = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.texcoord);
				/*
				float2x2 filter = { topLeftUV,    topRightUV, 
									bottomLeftUV, bottomRightUV };*/

				// BEGIN: Roberts cross filter operation --------
				// subtract across filter kernel diagonals 
				float depthBottomLeft = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, bottomLeftUV).r;
				float depthTopRight = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, topRightUV).r;
				float depthBottomRight = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, bottomRightUV).r;
				float depthTopLeft = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, topLeftUV).r;

				float depthDifferential0 = depthTopRight - depthBottomLeft;
				float depthDifferential1 = depthTopLeft - depthBottomRight;

				// compute final depth differential according to the Roberts Cross filter
				float depthDifferentialFinal = sqrt(pow(depthDifferential0, 2.0f) + pow(depthDifferential1, 2.0f)) * 100.0f; // scale by large factor to improve visibility
				// END: Roberts cross filter operation --------

				// BEGIN: Roberts cross with normals --------
				// the roberts cross filter misses some edges, which we can detect using the view-space normal map
				float3 normalBL = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, bottomLeftUV).rgb;
				float3 normalTR = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, topRightUV).rgb;
				float3 normalBR = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, bottomRightUV).rgb;
				float3 normalTL = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, topLeftUV).rgb;

				// we only want to light up an edge if the differential in the normals is also sufficiently large
				float3 normalDifferential0 = normalTR - normalBL;
				float3 normalDifferential1 = normalTL - normalBR;
				// END: Roberts cross with normals --------

				// If a surface is angled away from the camera, 
				// adjacent texels in the depth texture will appear to be far away enough from each other
				// even though we actually have a constant depth gradient, not an edge.
				// We can fix this by using information from the camera's surface normal map 
				// to change the depth differential threshold.

				// the normal differential ranges [0, 1], 
				// but the unprojected viewing directions range from [-1, 1] in each component.
				float3 normalAtPix = normalBL * 2.0f - float3(1.0f, 1.0f, 1.0f);
				float NdotV = 1.0f - dot(normalAtPix, -i.viewDir);

				// only surfaces that sufficiently face away from the camera need to be considered,
				// so we take elements between a lower bound and 1 and scale them between 1 and a user-defined
				// upper bound.
				float normalThreshold =
					saturate((NdotV - _DepthNormalLowerBound) / (1.0f - _DepthNormalLowerBound))
					* _DepthNormalScale
					+ 1.0f;

				// to account for the nonlinearity of the depth texture, multiply by the existing depth.
				// maybe better to just linearize the depth texture??
				float depthDiffThresh = _DepthDiffThreshold 
					* depthTopLeft 
					* normalThreshold; // increase the depth threshold if the angle between the view dir and the normal is large enough
				depthDifferentialFinal = depthDifferentialFinal > depthDiffThresh ? 1.0f : 0.0f;

				// this is the same roberts cross filter operation but hacked to work with 3D vectors
				float normalDifferentialFinal = sqrt(dot(normalDifferential0, normalDifferential0) + dot(normalDifferential1, normalDifferential1));
				normalDifferentialFinal = normalDifferentialFinal > _NormalDiffThreshold ? 1 : 0;

				bool edgeLit = max(depthDifferentialFinal, normalDifferentialFinal);
				float4 edgeColour = float4(_EdgeColour.rgb, 1.0f) * edgeLit; // float4(_EdgeColour.rgb, _EdgeColour.a * edgeLit);
				
				return alphaBlend(edgeColour, colour);
				// return colour;
			}
			ENDHLSL
		}

		// The second pass downsamples the main texture to get a low-res version
		// Barely passable pixel art post-processing shader, works for now as a starting point
		Pass
		{
			Name "Pixelization"

			HLSLPROGRAM
			#pragma vertex Vert
			#pragma fragment Frag

			#include "Packages/com.unity.postprocessing/PostProcessing/Shaders/StdLib.hlsl"

			// TEXTURE2D_SAMPLER2D(_MainTex, sampler_MainTex);
			TEXTURE2D_SAMPLER2D(_MainTex, sampler_point_clamp);
			// Data pertaining to _MainTex's dimensions.
			// https://docs.unity3d.com/Manual/SL-PropertiesInPrograms.html
			
			// TEXTURE2D(_MainTex);
			float4 _MainTex_TexelSize;
			float4 _MainTex_ST;

			// SamplerState sampler_point_clamp;
			float2 _SuperPixelSize;
			float2 _HalfSuperPixelSize;
			float2 _SuperPixelCount;

			struct VertDataModule
			{
				float4 vertex : SV_POSITION;
				float2 texcoord : TEXCOORD0;
				float2 texcoordStereo : TEXCOORD1;
				// float4 

			#if STEREO_INSTANCING_ENABLED
				uint stereoTargetEyeIndex : SV_RenderTargetArrayIndex;
			#endif
			};

			VertDataModule Vert(AttributesDefault v) // contains the varyings
			{
				VertDataModule vdm;
				vdm.vertex = float4(v.vertex.xy, 0.0, 1.0); // clip space (NDC) ranges from (-1, -1) to (1, 1)
				vdm.texcoord = TransformTriangleVertexToUV(v.vertex.xy);

			#if UNITY_UV_STARTS_AT_TOP
				vdm.texcoord = vdm.texcoord * float2(1.0, -1.0) + float2(0.0, 1.0);
			#endif

				vdm.texcoordStereo = TransformStereoScreenSpaceTex(vdm.texcoord, 1.0);
				return vdm;
			}

			float4 Frag(VertDataModule i) : SV_Target
			{
				float2 superPixPos = floor(i.texcoordStereo * _SuperPixelCount);
				float2 superPixCentre = superPixPos * _SuperPixelSize + _HalfSuperPixelSize;

				// float4 colour = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.texcoord);
				float4 colour = SAMPLE_TEXTURE2D(_MainTex, sampler_point_clamp, superPixCentre);

				return 0;
			}
			ENDHLSL
		}
	}
}