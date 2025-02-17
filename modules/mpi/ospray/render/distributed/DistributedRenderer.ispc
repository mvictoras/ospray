// Copyright 2009-2021 Intel Corporation
// SPDX-License-Identifier: Apache-2.0

#include "DistributedRenderer.ih"
#include "common/DistributedWorld.ih"
#include "common/Intersect.ih"
#include "common/Ray.ih"
#include "common/World.ih"
#include "math/random.ih"
#include "render/util.ih"

unmasked void markRegionVisibleFilterFunction(
    const RTCFilterFunctionNArguments *uniform args)
{
  if (!args->valid[programIndex]) {
    return;
  }

  EmbreeIntersectionContext *uniform ctx =
      (EmbreeIntersectionContext * uniform) args->context;

  bool *uniform regionVisible = (bool *uniform)ctx->userPtr;
  varying RTCHit *uniform hit = (varying RTCHit * uniform) args->hit;
  regionVisible[hit->primID] = true;

  // Reject all hits, we want to find all intersections along the ray to find
  // all visible regions
  args->valid[programIndex] = 0;
}

unmasked void DR_default_computeRegionVisibility(
    DistributedRenderer *uniform self,
    FrameBuffer *uniform fb,
    Camera *uniform camera,
    DistributedWorld *uniform world,
    bool *uniform regionVisible,
    void *uniform perFrameData,
    uniform Tile &tile,
    uniform int taskIndex)
{
  // TODO: merge the copy-paste here somewhat?
  const uniform int32 spp = self->super.spp;

  ScreenSample screenSample;
  screenSample.z = inf;
  screenSample.alpha = 0.f;

  CameraSample cameraSample;

  const z_order_t *uniform zOrder = get_zorder();

  const uniform int begin = taskIndex * RENDERTILE_PIXELS_PER_JOB;
  const uniform int end = begin + RENDERTILE_PIXELS_PER_JOB;
  const uniform int startSampleID = max(tile.accumID, 0) * spp;

  for (uniform uint32 i = begin; i < end; i += programCount) {
    const uint32 index = i + programIndex;
    screenSample.sampleID.x = tile.region.lower.x + zOrder->xs[index];
    screenSample.sampleID.y = tile.region.lower.y + zOrder->ys[index];

    if ((screenSample.sampleID.x >= fb->size.x)
        || (screenSample.sampleID.y >= fb->size.y))
      continue;

    float tMax = inf;
    // set ray t value for early ray termination if we have a maximum depth
    // texture
    if (self->super.maxDepthTexture) {
      // always sample center of pixel
      vec2f depthTexCoord;
      depthTexCoord.x = (screenSample.sampleID.x + 0.5f) * fb->rcpSize.x;
      depthTexCoord.y = (screenSample.sampleID.y + 0.5f) * fb->rcpSize.y;

      DifferentialGeometry lookup;
      initDgFromTexCoord(lookup, depthTexCoord);
      tMax = min(get1f(self->super.maxDepthTexture, lookup), inf);
    }

    const uint32 pixel = zOrder->xs[index] + (zOrder->ys[index] * TILE_SIZE);

    // TODO: Does spp still show some block boundary artifacts? Check
    // and maybe just support spp = 1 in DR
    for (uniform uint32 s = 0; s < spp; s++) {
      const float pixel_du = Halton_sample2(startSampleID + s);
      const float pixel_dv = CranleyPattersonRotation(
          Halton_sample3(startSampleID + s), 1.f / 6.f);
      screenSample.sampleID.z = startSampleID + s;

      cameraSample.screen.x =
          (screenSample.sampleID.x + pixel_du) * fb->rcpSize.x;
      cameraSample.screen.y =
          (screenSample.sampleID.y + pixel_dv) * fb->rcpSize.y;

      // no DoF or MB per default
      cameraSample.lens.x = 0.0f;
      cameraSample.lens.y = 0.0f;
      cameraSample.time = 0.5f;

      camera->initRay(camera, screenSample.ray, cameraSample);
      screenSample.ray.t = min(screenSample.ray.t, tMax);

      if (world->regionScene) {
        uniform EmbreeIntersectionContext context;
        rtcInitIntersectContext(&context.ectx);
        context.ectx.filter = markRegionVisibleFilterFunction;
        context.userPtr = regionVisible;
        rtcIntersectV(world->regionScene,
            &context.ectx,
            (varying RTCRayHit * uniform) & screenSample.ray);
      }
    }

    screenSample.rgb = make_vec3f(
        self->super.bgColor.x, self->super.bgColor.y, self->super.bgColor.z);
    screenSample.alpha = self->super.bgColor.z;
    screenSample.normal = make_vec3f(0.f);
    screenSample.albedo = make_vec3f(0.f);
    setTile(tile, pixel, screenSample);
  }
}

void DR_default_renderRegionSample(DistributedRenderer *uniform self,
    FrameBuffer *uniform fb,
    DistributedWorld *uniform world,
    const box3f *uniform region,
    const vec2f &regionInterval,
    void *uniform perFrameData,
    varying ScreenSample &sample)
{
  sample.z = inf;
  sample.alpha = 1.f;
  sample.rgb = make_random_color((sample.sampleID.x << 0)
      + (sample.sampleID.y << 14) + (sample.sampleID.z << 28));
}

unmasked void DR_default_renderRegionToTile(DistributedRenderer *uniform self,
    FrameBuffer *uniform fb,
    Camera *uniform camera,
    DistributedWorld *uniform world,
    const box3f *uniform region,
    void *uniform perFrameData,
    uniform Tile &tile,
    uniform int taskIndex)
{
  const uniform int32 spp = self->super.spp;

  ScreenSample screenSample;
  screenSample.z = inf;
  screenSample.alpha = 0.f;

  CameraSample cameraSample;

  const z_order_t *uniform zOrder = get_zorder();

  const uniform int begin = taskIndex * RENDERTILE_PIXELS_PER_JOB;
  const uniform int end = begin + RENDERTILE_PIXELS_PER_JOB;
  const uniform int startSampleID = max(tile.accumID, 0) * spp;

  for (uniform uint32 i = begin; i < end; i += programCount) {
    const uint32 index = i + programIndex;
    screenSample.sampleID.x = tile.region.lower.x + zOrder->xs[index];
    screenSample.sampleID.y = tile.region.lower.y + zOrder->ys[index];

    if ((screenSample.sampleID.x >= fb->size.x)
        || (screenSample.sampleID.y >= fb->size.y))
      continue;

    float tMax = inf;
    // set ray t value for early ray termination if we have a maximum depth
    // texture
    if (self->super.maxDepthTexture) {
      // always sample center of pixel
      vec2f depthTexCoord;
      depthTexCoord.x = (screenSample.sampleID.x + 0.5f) * fb->rcpSize.x;
      depthTexCoord.y = (screenSample.sampleID.y + 0.5f) * fb->rcpSize.y;

      DifferentialGeometry lookup;
      initDgFromTexCoord(lookup, depthTexCoord);
      tMax = min(get1f(self->super.maxDepthTexture, lookup), inf);
    }
    vec3f col = make_vec3f(0.f);
    float alpha = 0.f;
    vec3f normal = make_vec3f(0.f);
    vec3f albedo = make_vec3f(0.f);

    const uint32 pixel = zOrder->xs[index] + (zOrder->ys[index] * TILE_SIZE);

    // TODO: same note on spp > 1 issues
    for (uniform uint32 s = 0; s < spp; s++) {
      const float pixel_du = Halton_sample2(startSampleID + s);
      const float pixel_dv = CranleyPattersonRotation(
          Halton_sample3(startSampleID + s), 1.f / 6.f);
      screenSample.sampleID.z = startSampleID + s;

      cameraSample.screen.x =
          (screenSample.sampleID.x + pixel_du) * fb->rcpSize.x;
      cameraSample.screen.y =
          (screenSample.sampleID.y + pixel_dv) * fb->rcpSize.y;

      // no DoF or MB per default
      cameraSample.lens.x = 0.0f;
      cameraSample.lens.y = 0.0f;
      cameraSample.time = 0.5f;

      camera->initRay(camera, screenSample.ray, cameraSample);
      screenSample.ray.t = min(screenSample.ray.t, tMax);

      // TODO: We could store and use the region t intervals from when
      // we did the visibility test?
      Intersections isect =
          intersectBox(screenSample.ray.org, screenSample.ray.dir, *region);

      if (isect.entry.t < isect.exit.t && isect.exit.t >= screenSample.ray.t0
          && isect.entry.t <= screenSample.ray.t) {
        const float regionEnter = max(isect.entry.t, screenSample.ray.t0);
        const float regionExit = min(isect.exit.t, screenSample.ray.t);
        screenSample.ray.t0 = regionEnter;
        screenSample.ray.t = regionExit;
        self->renderRegionSample(self,
            fb,
            world,
            region,
            make_vec2f(regionEnter, regionExit),
            perFrameData,
            screenSample);

        col = col + screenSample.rgb;
        alpha += screenSample.alpha;
        normal = normal + screenSample.normal;
        albedo = albedo + screenSample.albedo;
      }
    }
    const float rspp = rcpf(spp);
    screenSample.rgb = col * rspp;
    screenSample.alpha = alpha * rspp;
    screenSample.normal = normal * rspp;
    screenSample.albedo = albedo * rspp;
    setTile(tile, pixel, screenSample);
  }
}

void DistributedRenderer_Constructor(uniform DistributedRenderer *uniform self)
{
  Renderer_Constructor(&self->super);

  self->computeRegionVisibility = DR_default_computeRegionVisibility;
  self->renderRegionSample = DR_default_renderRegionSample;
  self->renderRegionToTile = DR_default_renderRegionToTile;
}

export void DistributedRenderer_computeRegionVisibility(void *uniform _self,
    void *uniform fb,
    void *uniform camera,
    void *uniform world,
    bool *uniform regionVisible,
    void *uniform perFrameData,
    uniform Tile &tile,
    uniform int taskIndex)
{
  DistributedRenderer *uniform self =
      (uniform DistributedRenderer * uniform) _self;
  self->computeRegionVisibility(self,
      (FrameBuffer * uniform) fb,
      (Camera * uniform) camera,
      (DistributedWorld * uniform) world,
      regionVisible,
      perFrameData,
      tile,
      taskIndex);
}

export void DistributedRenderer_renderRegionToTile(void *uniform _self,
    void *uniform fb,
    void *uniform camera,
    void *uniform world,
    const void *uniform region,
    void *uniform perFrameData,
    uniform Tile &tile,
    uniform int taskIndex)
{
  DistributedRenderer *uniform self =
      (uniform DistributedRenderer * uniform) _self;
  self->renderRegionToTile(self,
      (FrameBuffer * uniform) fb,
      (Camera * uniform) camera,
      (DistributedWorld * uniform) world,
      (const box3f *uniform)region,
      perFrameData,
      tile,
      taskIndex);
}

export void DistributedRenderer_pick(const void *uniform _self,
    const void *uniform _fb,
    const void *uniform _camera,
    const void *uniform _world,
    const uniform vec2f &screenPos,
    uniform vec3f &pos,
    uniform int32 &instID,
    uniform int32 &geomID,
    uniform int32 &primID,
    uniform float &depth,
    uniform int32 &hit)
{
  const Renderer *uniform self = (const Renderer *uniform)_self;
  const FrameBuffer *uniform fb = (const FrameBuffer *uniform)_fb;
  const Camera *uniform camera = (const Camera *uniform)_camera;
  const DistributedWorld *uniform world =
      (const DistributedWorld *uniform)_world;

  CameraSample cameraSample;
  cameraSample.screen.x = screenPos.x;
  cameraSample.screen.y = screenPos.y;
  // use center of lens and shutter time
  cameraSample.lens.x = 0.0f;
  cameraSample.lens.y = 0.0f;
  cameraSample.time = 0.5f;

  Ray ray;
  camera->initRay(camera, ray, cameraSample);
  ray.t = min(ray.t, Renderer_getMaxDepth(self, cameraSample.screen));

  // Clip the ray to each region and trace the clipped ray to find the picked
  // object
  float closestHit = 1e20f;
  for (uniform int i = 0; i < world->numRegions; ++i) {
    // Separate ray per-region to allow clipping by the region's bounds
    Ray regionRay = ray;
    regionRay.t = min(ray.t, closestHit);

    const Intersections isect =
        intersectBox(regionRay.org, regionRay.dir, world->regions[i]);

    cif (isect.entry.t < isect.exit.t && isect.exit.t >= regionRay.t0
        && isect.entry.t <= regionRay.t) {
      regionRay.t0 = isect.entry.t;
      regionRay.t = min(regionRay.t, isect.exit.t);
      traceRay(&world->super, regionRay);

      cif (hadHit(regionRay)) {
        closestHit = regionRay.t;
        vec3f p = regionRay.org + regionRay.dir * regionRay.t;

        pos.x = extract(p.x, 0);
        pos.y = extract(p.y, 0);
        pos.z = extract(p.z, 0);
        hit = extract((int)(hadHit(regionRay)), 0);
        instID = extract(regionRay.instID, 0);
        geomID = extract(regionRay.geomID, 0);
        primID = extract(regionRay.primID, 0);
        depth = extract(regionRay.t, 0);
      }
    }
  }
}
