// Copyright 2009-2021 Intel Corporation
// SPDX-License-Identifier: Apache-2.0

#include "../bsdfs/RobustThinDielectric.ih"
#include "Material.ih"
#include "texture/TextureParam.ih"

struct ThinGlass
{
  PathTraceMaterial super;

  float eta; //!< reciprocal refraction index of internal medium
             // assumed to be <=1
  vec3f attenuation; //!< negative Napierian attenuation coefficient,
                     // i.e. wrt. the natural base e
  float attenuationScale; //!< factor to scale attenuation from texture due to
                          // thickness and attenuationDistance
  TextureParam attenuationColorMap;
};

///////////////////////////////////////////////////////////////////////////////
// Implementation

static inline const vec3f getAttenuation(
    const ThinGlass *uniform self, const DifferentialGeometry &dg)
{
  vec3f attenuation =
      self->attenuation + logf(make_vec3f(dg.color)) * self->attenuationScale;

  if (valid(self->attenuationColorMap)) {
    vec3f attenuationColor = get3f(self->attenuationColorMap, dg);
    attenuation = attenuation + logf(attenuationColor) * self->attenuationScale;
  }

  return attenuation;
}

const varying BSDF *varying ThinGlass_getBSDF(
    const PathTraceMaterial *uniform super,
    ShadingContext *uniform ctx,
    const DifferentialGeometry &dg,
    const Ray &ray,
    const Medium &currentMedium)
{
  const ThinGlass *uniform self = (const ThinGlass *uniform)super;

  varying linear3f *uniform frame = LinearSpace3f_create(ctx, frame(dg.Ns));
  return RobustThinDielectric_create(
      ctx, frame, self->eta, getAttenuation(self, dg));
}

vec3f ThinGlass_getTransparency(const PathTraceMaterial *uniform material,
    const DifferentialGeometry &dg,
    const Ray &ray,
    const Medium &currentMedium)
{
  const ThinGlass *uniform self = (const ThinGlass *uniform)material;

  float cosThetaO = max(-dot(ray.dir, dg.Ns), 0.0f);
  return RobustThinDielectric_getTransparency(
      cosThetaO, self->eta, getAttenuation(self, dg));
}

///////////////////////////////////////////////////////////////////////////////
// External API

export void PathTracer_ThinGlass_set(void *uniform _self,
    const uniform float ior,
    const uniform vec3f &attenuationColor,
    const uniform TextureParam &attenuationColorMap,
    const uniform float attenuationDistance,
    const uniform float thickness)
{
  ThinGlass *uniform self = (ThinGlass * uniform) _self;
  self->eta = rcp(ior);
  self->attenuationScale = thickness * rcp(max(attenuationDistance, EPS));
  self->attenuation = logf(attenuationColor) * self->attenuationScale;
  self->attenuationColorMap = attenuationColorMap;
}

export void *uniform PathTracer_ThinGlass_create()
{
  ThinGlass *uniform self = uniform new ThinGlass;
  PathTraceMaterial_Constructor(
      &self->super, MATERIAL_TYPE_THINGLASS, ThinGlass_getBSDF, ThinGlass_getTransparency);
  PathTracer_ThinGlass_set(
      self, 1.5f, make_vec3f(1.f), make_TextureParam(), 1.f, 1.f);

  return self;
}
