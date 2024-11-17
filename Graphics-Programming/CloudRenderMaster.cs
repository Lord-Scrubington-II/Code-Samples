using System.Collections;
using System.Collections.Generic;
using UnityEngine;

[ExecuteInEditMode] [ImageEffectAllowedInSceneView]
public class CloudRenderMaster : MonoBehaviour
{
    private Camera masterCam;
    [Header(" - Scene & Asset Refs -")]
    [SerializeField] private Light sun;  // set in inspector, should be the scene's directional light. 

    [SerializeField] private Shader cloudShader;
    [SerializeField] private Transform cloudContainer; // a transform that defines the box surrounding the cloud.
    private Material cloudMaterial; // used to pass inspector vars

    // 3D Perlin-Worley shape and detail noise textures passed from inspector
    [SerializeField] private Texture3D cloudShapeNoise;
    [SerializeField] private Texture3D cloudDetailNoise;
    [SerializeField] private Texture blueNoise; // for softening image by jittering raymarch start position

    // - BEGIN: Cloud sampling control vars -------

    [Header (" - Cloud Sampling Control Vars -")]
    // Shape
    [SerializeField] private Vector3 cloudsOffset = new Vector3(0.0f, 0.0f, 0.0f); // should allow the cloud to "move" in the box
    [SerializeField] private float cloudsScale = 1.0f; // used to manipulate the mapping from texture to world space
    [SerializeField] private Vector4 cloudShapeNoiseWeights = new Vector4(1.0f, 0.0f, 0.0f, 0.0f); // relative weights to be used for the 4 different shape noise channels.
    
    // Detail
    [SerializeField] private Vector3 cloudDetailOffset = new Vector3(0.0f, 0.0f, 0.0f); // should allow the cloud to "move" in the box
    [SerializeField] private float cloudDetailScale = 1.0f; // used to manipulate the mapping from texture to world space
    [SerializeField] [Range(0, 3)] private float cloudDetailWeight = 1.0f; // used to manipulate importance of the detail noise
    [SerializeField] private Vector3 detailNoiseChannelWeights = new Vector3(1.0f, 0.0f, 0.0f); // relative weights to be used for the 3 different shape noise channels.

    [SerializeField] [Range(1, 200)] private int sampleCount = 6; // controls # of steps taken when marching the light ray
    [SerializeField] [Range(1, 10)] private int lightSampleCount = 5; // controls # of steps taken when marching the light ray
    [SerializeField] [Range(0, 15)] private float blueNoiseStrength = 5; // controls # of steps taken when marching the light ray
    [SerializeField] [Range(0, 10)] private float emptySpaceOffset = 0.2f; // any density reading below this threshold is considered 0

    // - End: Cloud sampling control vars ---------

    [Header(" - Lighting Params -")]
    // Lighting
    [SerializeField] private float densityControlMultiplier = 1.0f; // just a multiplier for the density reading, should be used to manipulate cloud darkness
    [SerializeField] private float absorptionCoefficient = 1.0f; // controls light attenuation along primary ray
    [SerializeField] private float absorptionCoefficientToSun = 1.0f; // controls light attenuation along secondary rays
    [SerializeField] [Range(0, 1)] private float darknessThreshold = 0.5f; // controls # of steps taken when marching the light ray
    [SerializeField] [Range(-1, 1)] private float forwardScattering = 0.5f; // the scattering term of the Henyey-Greenstein phase function.
    [SerializeField] [Range(0, 1)] private float scatteringCoefficient = 0.2f; // the scattering term of the Henyey-Greenstein phase function.


    public Vector3 CloudsOffset { get => cloudsOffset; set => cloudsOffset = value; }
    public float CloudsScale { get => cloudsScale; set => cloudsScale = value; }
    public float EmptySpaceOffset { get => emptySpaceOffset; set => emptySpaceOffset = value; }
    public float DensityControlMultiplier { get => densityControlMultiplier; set => densityControlMultiplier = value; }
    public int SampleCount { get => sampleCount; set => sampleCount = value; }
    public int LightSampleCount { get => lightSampleCount; set => lightSampleCount = value; }
    public float AbsorptionCoefficient { get => absorptionCoefficient; set => absorptionCoefficient = value; }
    public float DarknessThreshold { get => darknessThreshold; set => darknessThreshold = value; }
    public Vector4 ShapeNoiseWeights { get => cloudShapeNoiseWeights; set => cloudShapeNoiseWeights = value; }
    public Vector3 CloudDetailOffset { get => cloudDetailOffset; set => cloudDetailOffset = value; }
    public float CloudDetailScale { get => cloudDetailScale; set => cloudDetailScale = value; }
    public Vector3 DetailNoiseChannelWeights { get => detailNoiseChannelWeights; set => detailNoiseChannelWeights = value; }
    public float CloudDetailWeight { get => cloudDetailWeight; set => cloudDetailWeight = value; }
    public float ForwardScattering { get => forwardScattering; set => forwardScattering = value; }
    public float ScatteringCoefficient { get => scatteringCoefficient; set => scatteringCoefficient = value; }
    public float BlueNoiseStrength { get => blueNoiseStrength; set => blueNoiseStrength = value; }
    public float AbsorptionCoefficientToSun { get => absorptionCoefficientToSun; set => absorptionCoefficientToSun = value; }

    private void Awake()
    {
        masterCam = gameObject.GetComponent<Camera>();
        // noiseGenerator = FindObjectOfType<NoiseGenerator>();
    }

    private void OnRenderImage(RenderTexture source, RenderTexture destination)
    {
        if (cloudMaterial == null) {
            cloudMaterial = new Material(cloudShader);
        }

        PassShaderParams();

        // When Graphics.Blit() is called with a material argument,
        // it sets the _Maintex property on the material to the src texture.
        // Then, it sets the render target to the destination texture as usual.
        // This will let me use an image effect shader to modify the image after 
        // it has gone through the graphics pipeline.
        Graphics.Blit(source, destination, cloudMaterial);
    }

    private void PassShaderParams()
    {
        // - Lights ---------------------------------
        Vector3 sunlight_dir = sun.transform.forward;
        cloudMaterial.SetVector("_SunDir", sunlight_dir);
        cloudMaterial.SetVector("_SunColour", sun.color);

        // - Camera ---------------------------------
        // pass the camera's model-view and projection matrix inverses to the compute shader
        // cloudMaterial.SetMatrix("_CameraToWorld", masterCam.cameraToWorldMatrix); // nvm, it is already accessible in this fragment shader
        cloudMaterial.SetMatrix("_CameraInverseProjection", masterCam.projectionMatrix.inverse);

        // - Action --------------------------------- // (lol)
        // Pass the cloud container's boundary points
        cloudMaterial.SetVector("_BoxMax", cloudContainer.position + cloudContainer.localScale / 2.0f);
        cloudMaterial.SetVector("_BoxMin", cloudContainer.position - cloudContainer.localScale / 2.0f);

        // Pass the 3D noise textures
        cloudMaterial.SetTexture("_Worley", cloudShapeNoise);
        cloudMaterial.SetTexture("_Perlin", cloudDetailNoise);
        cloudMaterial.SetTexture("_BlueNoise", blueNoise);

        // Pass the cloud control vars
        cloudMaterial.SetVector("_CloudsOffset", CloudsOffset);
        cloudMaterial.SetFloat("_CloudsScale", CloudsScale);
        cloudMaterial.SetVector("_ShapeNoiseWeights", ShapeNoiseWeights);

        cloudMaterial.SetVector("_DetailOffset", CloudDetailOffset);
        cloudMaterial.SetFloat("_DetailScale", CloudDetailScale);
        cloudMaterial.SetVector("_DetailNoiseWeights", DetailNoiseChannelWeights);
        cloudMaterial.SetFloat("_DetailNoiseOverallWeight", CloudDetailWeight);

        cloudMaterial.SetFloat("_DensityReadOffset", EmptySpaceOffset);
        cloudMaterial.SetFloat("_DensityMult", DensityControlMultiplier);
        cloudMaterial.SetFloat("_AbsorptionCoeff", AbsorptionCoefficient);
        cloudMaterial.SetFloat("_AbsorptionCoeffSecondary", AbsorptionCoefficientToSun);
        cloudMaterial.SetFloat("_DarknessThreshold", DarknessThreshold);
        cloudMaterial.SetFloat("_ScatteringTerm", ForwardScattering);
        cloudMaterial.SetFloat("_ScatteringCoeff", ScatteringCoefficient);

        cloudMaterial.SetInt("_NumSamples", SampleCount);
        cloudMaterial.SetInt("_StepsToLight", LightSampleCount);
        cloudMaterial.SetFloat("_BlueNoiseStrength", BlueNoiseStrength);

        // cloudMaterial.SetFloat("_LightScatteringMult", LightScatteringMultiplier);
    }
}
