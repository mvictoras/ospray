// Copyright 2009-2021 Intel Corporation
// SPDX-License-Identifier: Apache-2.0

// ospray
#include "VolumetricModel.ih"
#include "common/Ray.ih"
#include "rkcommon/math/box.ih"
#include "rkcommon/math/vec.ih"

export void *uniform VolumetricModel_create()
{
  VolumetricModel *uniform self = uniform new VolumetricModel;
  return self;
}

export void VolumetricModel_set(void *uniform _self,
    void *uniform volume,
    void *uniform transferFunction,
    const uniform box3f &bounds,
    uniform float densityScale,
    uniform float anisotropy,
    uniform float gradientShadingScale)
{
  VolumetricModel *uniform self = (VolumetricModel * uniform) _self;

  self->transferFunction = (TransferFunction * uniform) transferFunction;
  self->boundingBox = bounds;
  self->densityScale = densityScale;
  self->anisotropy = anisotropy;
  self->gradientShadingScale = gradientShadingScale;
  self->volume = (Volume * uniform) volume;
}

export void VolumetricModel_set_intervalContext(
    void *uniform _self, void *uniform intervalContext)
{
  VolumetricModel *uniform self = (VolumetricModel * uniform) _self;
  self->vklIntervalContext = (VKLIntervalIteratorContext)intervalContext;
}
