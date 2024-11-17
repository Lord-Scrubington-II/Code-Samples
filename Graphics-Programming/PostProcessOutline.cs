using System;
using UnityEngine;
using UnityEngine.Rendering.PostProcessing;

[Serializable]
[PostProcess(typeof(PostProcessOutlineRenderer), PostProcessEvent.BeforeStack, "Roystan-Wang/Post Process Outline")]
public sealed class PostProcessOutline : PostProcessEffectSettings
{
	[Range(1, 7)] public IntParameter edgeFilterScale = new IntParameter { value = 1 };
	public FloatParameter depthDiffThreshold = new FloatParameter { value = 1.5f };
	
	[Range(0, 1)] public FloatParameter normalDiffThreshold = new FloatParameter { value = 0.3f };

	[Range(0, 1)] public FloatParameter depthNormalThreshold = new FloatParameter { value = 0.5f };
	public FloatParameter depthNormalThresholdScale = new FloatParameter { value = 7.0f };

	public ColorParameter edgeColour = new ColorParameter { value = Color.white };

	[Range(100, 1080)] public IntParameter virtualScreenHeight = new IntParameter { value = 500 };
}

public sealed class PostProcessOutlineRenderer : PostProcessEffectRenderer<PostProcessOutline>
{
	public override void Render(PostProcessRenderContext context)
	{
		var sheet = context.propertySheets.Get(Shader.Find("Roystan-Wang/Post Process Outline"));
		sheet.properties.SetFloat("_EdgeFilterScale", this.settings.edgeFilterScale);
		sheet.properties.SetFloat("_DepthDiffThreshold", this.settings.depthDiffThreshold);
		sheet.properties.SetFloat("_NormalDiffThreshold", this.settings.normalDiffThreshold);

		sheet.properties.SetFloat("_DepthNormalLowerBound", settings.depthNormalThreshold);
		sheet.properties.SetFloat("_DepthNormalScale", settings.depthNormalThresholdScale);

		// pass the main cam's inverse projection matrix to the edge shader
		Matrix4x4 invProjection = GL.GetGPUProjectionMatrix(context.camera.projectionMatrix, true).inverse;
		sheet.properties.SetMatrix("_InvProjectionMatrix", invProjection);

		sheet.properties.SetColor("_EdgeColour", settings.edgeColour);
		

		float aspect = context.screenWidth / context.screenHeight;
		int pixViewportW = (int)Mathf.Ceil(aspect * settings.virtualScreenHeight.value);
		int pixViewportH = settings.virtualScreenHeight;
		Vector2 superPixSize = new Vector2(1.0f / pixViewportW, 1.0f / pixViewportH);
		Vector2 halfSuperPixSize = new Vector2(0.5f / pixViewportW, 0.5f / pixViewportH);
		Vector2 superPixCount = new Vector2(pixViewportW, pixViewportH);
		sheet.properties.SetVector("_SuperPixelSize", superPixSize);
		sheet.properties.SetVector("_HalfSuperPixelSize", halfSuperPixSize);
		sheet.properties.SetVector("_SuperPixelCount", superPixCount);
		/*
		RenderTexture lowResRT = new RenderTexture(aspect * settings.screenHeight, settings.screenHeight, 24);
		context.command.BlitFullscreenTriangle(context.source, lowResRT, sheet, 0);
		*/
		context.command.BlitFullscreenTriangle(context.source, context.destination, sheet, 0);

	}
}