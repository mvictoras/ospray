// Copyright 2009-2021 Intel Corporation
// SPDX-License-Identifier: Apache-2.0

#include "World.ih"
#include "lights/Light.ih"
#include "math/Distribution1D.ih"
#include "render/pathtracer/GeometryLight.ih"

unmasked void clippingIntersectionFilterV(
    const struct RTCFilterFunctionNArguments *uniform args)
{
  // Set execution mask
  varying int *uniform valid = (varying int *uniform)args->valid;
  if (*valid == 0)
    return;

  // Get pointer to the intersection context
  uniform UserIntersectionContextForClipping *uniform context =
      (uniform UserIntersectionContextForClipping * uniform) args->context;

  // We skip this intersection to collect all remaining intersections
  *valid = 0;

  // Skip if array is full
  if (context->hitsCount >= CLIPPING_HITS_MAX_COUNT)
    return;

  // Get ray and hit
  varying Ray *uniform ray = (varying Ray * uniform) args->ray;
  varying const RTCHit *uniform hit = (varying const RTCHit *uniform)args->hit;

  // Prepare clipping normal
  vec3f Nc;
  {
    // The postIntersect function needs the hit part of the Ray structure to be
    // initialized. Making a ray copy here is quite costly. That is why just
    // the necessary ray fields are set here.
    DifferentialGeometry dg;
    ray->Ng = make_vec3f(hit->Ng_x, hit->Ng_y, hit->Ng_z);
    ray->u = hit->u;
    ray->v = hit->v;
    ray->primID = hit->primID;
    ray->geomID = hit->geomID;

    // We need to call postIntersect on clipping geometry
    foreach_unique (instID in hit->instID[0]) {
      // Call postIntersect to get shading normal
      Instance *uniform instance = *(context->world->clippersInst + instID);
      Instance_postIntersect(instance, NULL, dg, *ray, DG_NG | DG_NS, true);

      // Use geometry normal for clipping
      // but use shading normal to check if invertion is needed
      Nc = (dot(dg.Ns, dg.Ng) > 0.f) ? ray->Ng : neg(ray->Ng);
    }

    // Restore IDs initial values
    ray->primID = RTC_INVALID_GEOMETRY_ID;
    ray->geomID = RTC_INVALID_GEOMETRY_ID;
  }

  // Based on clipping normal vector decide if the ray is
  // entering clipping geometry (set positive hit value) or exitting clipping
  // geometry (set negative hit value)
  const bool exitsClipping = (dot(ray->dir, Nc) > 0.f);
  ClippingHit cHit;
  cHit.t = (exitsClipping) ? -ray->t : ray->t;
  cHit.primID = hit->primID;
  cHit.geomID = hit->geomID;
  cHit.instID = hit->instID[0];

  // Some geometry types (e.g. curves, subdivisions)
  // may give more than 2 intersections, we have to filter them out
  for (uint32 i = 0; i < context->hitsCount; i++) {
    if ((context->hits[i].primID == cHit.primID)
        && (context->hits[i].geomID == cHit.geomID)
        && (context->hits[i].instID == cHit.instID)
        && floatUlpCompare(context->hits[i].t, cHit.t, 512))
      return;
  }

  // Now we know that this intersection will be taken into account,
  // so we can update clipping depth correction value accordingly
  if (exitsClipping) {
    context->corrClippingDepth--;
  } else {
    context->corrClippingDepth++;
  }

  // Insert hit value into sorted array
  for (uint32 i = 0; i < context->hitsCount; i++) {
    if (abs(context->hits[i].t) > abs(cHit.t)) {
      const ClippingHit tmp = context->hits[i];
      context->hits[i] = cHit;
      cHit = tmp;
    }
  }
  context->hits[context->hitsCount] = cHit;
  context->hitsCount++;
}

void World_Constructor(World *uniform world)
{
  world->geometriesInst = NULL;
  world->numGeometriesInst = 0;
  world->volumesInst = NULL;
  world->numVolumesInst = 0;
  world->clippersInst = NULL;
  world->numClippersInst = 0;

  world->embreeSceneHandleGeometries = NULL;
  world->embreeSceneHandleVolumes = NULL;
  world->embreeSceneHandleClippers = NULL;

  world->numInvertedClippers = 0;

  world->scivisData.lights = NULL;
  world->scivisData.numLights = 0;
  world->scivisData.numLightsVisibleOnly = 0;

  world->pathtracerData.numLights = 0;
  world->pathtracerData.numGeoLights = 0;
  world->pathtracerData.lights = NULL;
  world->pathtracerData.lightsCDF = NULL;
}

inline void SciVisData_destroy(SciVisData *uniform self)
{
  // Delete all lights
  for (uniform int i = 0; i < self->numLights; i++)
    delete self->lights[i];

  delete[] self->lights;
}

inline void PathtracerData_destroy(PathtracerData *uniform self)
{
  for (uniform int i = 0; i < self->numGeoLights; i++)
    GeometryLight_destroy(self->lights[i]);

  for (uniform int i = self->numGeoLights; i < self->numLights; i++)
    delete self->lights[i];

  delete[] self->lights;
  delete[] self->lightsCDF;
}

export void *uniform World_create()
{
  World *uniform world = uniform new World;
  World_Constructor(world);
  return (void *uniform)world;
}

export void World_destroy(void *uniform _self)
{
  World *uniform self = (World * uniform) _self;

  SciVisData_destroy(&self->scivisData);
  PathtracerData_destroy(&self->pathtracerData);

  delete self;
}

export void World_set(void *uniform _self,
    void *uniform _geometriesInst,
    uniform int32 numGeometriesInst,
    void *uniform _volumesInst,
    uniform int32 numVolumesInst,
    void *uniform _clippersInst,
    uniform int32 numClippersInst,
    void *uniform embreeGeometryScene,
    void *uniform embreeVolumeScene,
    void *uniform embreeClipScene,
    uniform int32 numInvertedClippers)
{
  World *uniform self = (World * uniform) _self;
  Instance **uniform geometriesInst = (Instance * *uniform) _geometriesInst;
  Instance **uniform volumesInst = (Instance * *uniform) _volumesInst;
  Instance **uniform clippersInst = (Instance * *uniform) _clippersInst;

  self->geometriesInst = geometriesInst;
  self->numGeometriesInst = numGeometriesInst;

  self->volumesInst = volumesInst;
  self->numVolumesInst = numVolumesInst;

  self->clippersInst = clippersInst;
  self->numClippersInst = numClippersInst;

  self->embreeSceneHandleGeometries = (RTCScene)embreeGeometryScene;
  self->embreeSceneHandleVolumes = (RTCScene)embreeVolumeScene;
  self->embreeSceneHandleClippers = (RTCScene)embreeClipScene;

  self->numInvertedClippers = numInvertedClippers;
}

export void World_setSciVisData(void *uniform _self,
    const uniform vec3f &aoColor,
    void **uniform lights,
    const uniform uint32 numLights,
    const uniform uint32 numLightsVisibleOnly)
{
  World *uniform self = (World * uniform) _self;
  SciVisData *uniform svData = &self->scivisData;

  SciVisData_destroy(svData);

  svData->aoColorPi = aoColor * pi;
  svData->lights = NULL;
  svData->numLights = numLights;
  svData->numLightsVisibleOnly = numLightsVisibleOnly;
  if (numLights) {
    svData->lights = uniform new uniform LightPtr[numLights];
    LightArray srcLights = (LightArray)lights;
    for (uniform int i = 0; i < numLights; i++)
      svData->lights[i] = srcLights[i];
  }
}

export void World_setPathtracerData(void *uniform _self,
    void **uniform lights,
    const uniform uint32 numLights,
    const uniform uint32 numGeoLights)
{
  World *uniform self = (World * uniform) _self;
  PathtracerData *uniform ptData = &self->pathtracerData;

  PathtracerData_destroy(ptData);

  ptData->lights = NULL;
  ptData->lightsCDF = NULL;
  ptData->numLights = numLights;
  ptData->numGeoLights = numGeoLights;
  if (numLights) {
    ptData->lights = uniform new uniform LightPtr[numLights];
    ptData->lightsCDF = uniform new uniform float[numLights];
    LightArray srcLights = (LightArray)lights;
    for (uniform int i = 0; i < numLights; i++) {
      ptData->lights[i] = srcLights[i];
      ptData->lightsCDF[i] = 1.0f;
    }
    Distribution1D_create(numLights, ptData->lightsCDF);
  }
}
