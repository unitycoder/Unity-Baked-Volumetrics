﻿Shader "SceneVolumetricFog"
{
    Properties
    {
        [Header(Volume)]
        _VolumeTexture("Volume Texture", 3D) = "white" {}
        _VolumePos("Volume World Position", Vector) = (0, 0, 0, 0)
        _VolumeSize("Volume World Size", Vector) = (0, 0, 0, 0)

        [Header(Raymarching)]
        _RaymarchStepSize("Raymarch Step Size", Float) = 25

        [Header(Rendering)]
        [Toggle(_HALF_RESOLUTION)] _HalfResolution("Half Resolution", Float) = 0
        [Toggle(_ANIMATED_NOISE)] _EnableAnimatedJitter("Animated Noise", Float) = 0
        _JitterTexture("Jitter Texture", 2D) = "white" {}
        _RaymarchJitterStrength("Raymarch Jitter", Float) = 2
    }

    SubShader
    {
        Tags 
        { 
            "RenderType" = "Transparent" 
            "Queue" = "Transparent+2000" 
        }

        Cull Off
        ZWrite Off
        ZTest Off
        Blend SrcAlpha OneMinusSrcAlpha

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #pragma multi_compile_instancing  
            #pragma multi_compile SAMPLES_8 SAMPLES_16 SAMPLES_24 SAMPLES_32 SAMPLES_48 SAMPLES_64 SAMPLES_128

            #pragma shader_feature_local _ANIMATED_NOISE
            #pragma shader_feature_local _HALF_RESOLUTION

            #include "UnityCG.cginc"
            #include "QuadIntrinsics.cginc"

            //NOTE: IF MIP QUAD OPTIMIZATION IS ENABLED
            //WE HAVE TO TARGET 5.0
            #if defined (_HALF_RESOLUTION)
                //#pragma target 5.0
                //#pragma require interpolators10
                //#pragma require interpolators15
                //#pragma require interpolators32
                //#pragma require mrt4
                //#pragma require mrt8
                #pragma require derivatives
                //#pragma require samplelod
                //#pragma require fragcoord
                //#pragma require integers
                //#pragma require 2darray
                #pragma require cubearray
                //#pragma require instancing
                //#pragma require geometry
                //#pragma require compute
                //#pragma require randomwrite
                //#pragma require tesshw
                //#pragma require tessellation
                //#pragma require msaatex
                //#pragma require sparsetex
                //#pragma require framebufferfetch
            #endif

            ///*
            #ifdef SAMPLES_8
                #define _RaymarchSteps 8
            #elif SAMPLES_16
                #define _RaymarchSteps 16
            #elif SAMPLES_24
                #define _RaymarchSteps 24
            #elif SAMPLES_32
                #define _RaymarchSteps 32
            #elif SAMPLES_48
                #define _RaymarchSteps 48
            #elif SAMPLES_64
                #define _RaymarchSteps 64
            #elif SAMPLES_128
                #define _RaymarchSteps 128
            #else
                #define _RaymarchSteps 32
            #endif
            //*/

            //#define _RaymarchSteps 16384 //RTX 3080 STRESS TEST
            //#define _RaymarchSteps 32768 //RTX 3080 STRESS TEST
            //#define _RaymarchSteps 32

            struct appdata
            {
                fixed4 vertex : POSITION;

                //Single Pass Instanced Support
                UNITY_VERTEX_INPUT_INSTANCE_ID 
            };

            struct vertexToFragment
            {
                fixed4 vertex : SV_POSITION;
                fixed4 screenPos : TEXCOORD0;
                fixed3 camRelativeWorldPos : TEXCOORD1;

                //Single Pass Instanced Support
                UNITY_VERTEX_OUTPUT_STEREO
            };

            fixed _RaymarchStepSize;
            fixed _RaymarchJitterStrength;
            fixed4 _VolumePos;
            fixed4 _VolumeSize;
            fixed4 _JitterTexture_TexelSize;
            fixed4 _CameraDepthTexture_TexelSize;
            sampler2D_half _JitterTexture;
            sampler3D_half _VolumeTexture;
            UNITY_DECLARE_SCREENSPACE_TEXTURE(_CameraDepthTexture);

            #if defined (_ANIMATED_NOISE)
                //animated noise courtesy of silent
                fixed r2sequence(fixed2 pixel)
                {
                    const fixed a1 = 0.75487766624669276;
                    const fixed a2 = 0.569840290998;

                    return frac(a1 * fixed(pixel.x) + a2 * fixed(pixel.y));
                }

                fixed2 r2_modified(fixed idx, fixed2 seed)
                {
                    return frac(seed + fixed(idx) * fixed2(0.245122333753, 0.430159709002));
                }

                fixed noise(fixed2 uv)
                {
                    //uv += r2_modified(_Time.y, uv);
                    uv += fixed2(_Time.y, _Time.y);
                    uv *= _ScreenParams.xy * _JitterTexture_TexelSize.xy;

                    return tex2Dlod(_JitterTexture, fixed4(uv, 0, 0));
                }
            #else
                fixed noise(fixed2 uv)
                {
                    #if defined (_HALF_RESOLUTION)
                        return tex2Dlod(_JitterTexture, fixed4(uv * _ScreenParams.xy * _JitterTexture_TexelSize.xy * 0.5, 0, 0));
                    #else 
                        return tex2Dlod(_JitterTexture, fixed4(uv * _ScreenParams.xy * _JitterTexture_TexelSize.xy, 0, 0));
                    #endif
                }
            #endif

            vertexToFragment vert(appdata v)
            {
                vertexToFragment o;

                //Single Pass Instanced Support
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(vertexToFragment, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                o.vertex = UnityObjectToClipPos(v.vertex);
                o.screenPos = UnityStereoTransformScreenSpaceTex(ComputeScreenPos(o.vertex));
                o.camRelativeWorldPos = mul(unity_ObjectToWorld, fixed4(v.vertex.xyz, 1.0)).xyz - _WorldSpaceCameraPos;

                return o;
            }

            fixed4 frag(vertexToFragment i) : SV_Target
            {
                //Single Pass Instanced Support
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                #if defined (_HALF_RESOLUTION)
                    SETUP_QUAD_INTRINSICS(i.vertex)
                #endif

                //our final computed fog color
                fixed4 result = fixed4(0, 0, 0, 0); //rgb = fog color, a = transmittance

                #if defined (_HALF_RESOLUTION)
                    if (QuadGetLaneID() == 0)
                    {
                #endif

                //get our screen uv coords
                fixed2 screenUV = i.screenPos.xy / i.screenPos.w;

                #if UNITY_UV_STARTS_AT_TOP
                    if (_CameraDepthTexture_TexelSize.y < 0)
                        screenUV.y = 1 - screenUV.y;
                #endif

                #if UNITY_SINGLE_PASS_STEREO
                    // If Single-Pass Stereo mode is active, transform the
                    // coordinates to get the correct output UV for the current eye.
                    fixed4 scaleOffset = unity_StereoScaleOffset[unity_StereoEyeIndex];
                    screenUV = (screenUV - scaleOffset.zw) / scaleOffset.xy;
                #endif

                //draw our scene depth texture and linearize it
                fixed linearDepth = LinearEyeDepth(SAMPLE_DEPTH_TEXTURE_PROJ(_CameraDepthTexture, UNITY_PROJ_COORD(i.screenPos)));

                //calculate the world position view plane for the camera
                fixed3 cameraWorldPositionViewPlane = i.camRelativeWorldPos.xyz / dot(i.camRelativeWorldPos.xyz, unity_WorldToCamera._m20_m21_m22);

                //get the world position vector
                fixed3 worldPos = cameraWorldPositionViewPlane * linearDepth + _WorldSpaceCameraPos;

                //scale our vectors to the volume
                fixed3 scaledWorldPos = ((worldPos - _VolumePos) + _VolumeSize * 0.5) / _VolumeSize;
                fixed3 scaledCameraPos = ((_WorldSpaceCameraPos - _VolumePos) + _VolumeSize * 0.5) / _VolumeSize;

                // UV offset by orientation
                fixed3 localViewDir = normalize(UnityWorldSpaceViewDir(worldPos));

                //compute jitter
                fixed jitter = 1.0f + noise(screenUV + length(localViewDir)) * _RaymarchStepSize * _RaymarchJitterStrength;

                #if defined (_HALF_RESOLUTION)
                    jitter *= 2.0f;
                #endif

                //get our ray increment vector that we use so we can march into the scene. Jitter it also so we can mitigate banding/stepping artifacts
                fixed3 raymarch_rayIncrement = normalize(i.camRelativeWorldPos.xyz) / _RaymarchSteps;

                //get the length of the step
                fixed stepLength = length(raymarch_rayIncrement);

                //get our starting ray position from the camera
                fixed3 raymarch_currentPos = _WorldSpaceCameraPos + raymarch_rayIncrement * jitter;

                //start marching
                for (int i = 0; i < _RaymarchSteps; i++)
                {
                    //scale the current ray position to be within the volume
                    fixed3 scaledPos = ((raymarch_currentPos - _VolumePos) + _VolumeSize * 0.5) / _VolumeSize;

                    //get the distances of the ray and the world position
                    fixed distanceRay = distance(scaledCameraPos, scaledPos);
                    fixed distanceWorld = distance(scaledCameraPos, scaledWorldPos);

                    //make sure we are within our little box
                    if (scaledPos.x < 1.0f && scaledPos.x > 0.0f && scaledPos.y < 1.0f && scaledPos.y > 0.0f && scaledPos.z < 1.0f && scaledPos.z > 0.0f)
                    {
                        //IMPORTANT: Check the current position distance of our ray compared to where we started.
                        //If our distance is less than that of the world then that means we aren't intersecting into any objects yet so keep accumulating.
                        if (distanceRay < distanceWorld)
                        {
                            //And also keep going if we haven't reached the fullest density just yet.
                            if (result.a < 1.0f)
                            {
                                //sample the fog color (rgb = color, a = density)
                                fixed4 sampledColor = tex3Dlod(_VolumeTexture, fixed4(scaledPos, 0));

                                //accumulate the samples
                                result += fixed4(sampledColor.rgb, sampledColor.a) * stepLength; //this is slightly cheaper
                            }
                        }
                        else
                            break; //terminante the ray 
                    }

                    //keep stepping forward into the scene
                    raymarch_currentPos += raymarch_rayIncrement * _RaymarchStepSize;
                }

                //clamp the alpha channel otherwise we get blending issues with bright spots
                result.a = clamp(result.a, 0.0f, 1.0f);

                #if defined (_HALF_RESOLUTION)
                    }
                    return QuadReadLaneAt(result, uint2(0, 0));
                #endif

                //return the final fog color
                return result;
            }
            ENDCG
        }
    }
}
