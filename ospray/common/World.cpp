// Copyright 2009-2021 Intel Corporation
// SPDX-License-Identifier: Apache-2.0

// ospray
#include "World.h"
// ispc exports
#include "common/Instance_ispc.h"
#include "common/World_ispc.h"

namespace ospray {

// Embree helper functions ///////////////////////////////////////////////////

static void addGeometryInstance(RTCScene &scene,
    RTCScene instScene,
    const Instance *inst,
    RTCDevice embreeDevice)
{
  if (!embreeDevice)
    throw std::runtime_error("invalid Embree device");

  // Create parent scene if not yet created
  if (!scene)
    scene = rtcNewScene(embreeDevice);

  // Create geometry instance
  auto eInst = rtcNewGeometry(embreeDevice, RTC_GEOMETRY_TYPE_INSTANCE);
  rtcSetGeometryInstancedScene(eInst, instScene);
  inst->motionTransform.setEmbreeTransform(eInst);

  ispc::Instance_set_embreeGeom(inst->getIE(), eInst);

  rtcAttachGeometry(scene, eInst);
  rtcReleaseGeometry(eInst);
}

static void freeAndNullifyEmbreeScene(RTCScene &scene)
{
  if (scene)
    rtcReleaseScene(scene);

  scene = nullptr;
}

// World definitions ////////////////////////////////////////////////////////

World::~World()
{
  freeAndNullifyEmbreeScene(embreeSceneHandleGeometries);
  freeAndNullifyEmbreeScene(embreeSceneHandleVolumes);
  freeAndNullifyEmbreeScene(embreeSceneHandleClippers);
  ispc::World_destroy(getIE());
  ispcEquivalent = nullptr;
}

World::World()
{
  managedObjectType = OSP_WORLD;
  this->ispcEquivalent = ispc::World_create();
}

std::string World::toString() const
{
  return "ospray::World";
}

void World::commit()
{
  freeAndNullifyEmbreeScene(embreeSceneHandleGeometries);
  freeAndNullifyEmbreeScene(embreeSceneHandleVolumes);
  freeAndNullifyEmbreeScene(embreeSceneHandleClippers);

  scivisDataValid = false;
  pathtracerDataValid = false;

  instances = getParamDataT<Instance *>("instance");
  lights = getParamDataT<Light *>("light");

  auto numInstances = instances ? instances->size() : 0;

  int sceneFlags = 0;
  sceneFlags |=
      (getParam<bool>("dynamicScene", false) ? RTC_SCENE_FLAG_DYNAMIC : 0);
  sceneFlags |=
      (getParam<bool>("compactMode", false) ? RTC_SCENE_FLAG_COMPACT : 0);
  sceneFlags |=
      (getParam<bool>("robustMode", false) ? RTC_SCENE_FLAG_ROBUST : 0);

  postStatusMsg(OSP_LOG_DEBUG)
      << "=======================================================\n"
      << "Committing world, which has " << numInstances << " instances";

  geometriesInstIEs.clear();
  volumesInstIEs.clear();
  clippersInstIEs.clear();

  int numInvertedClippers = 0;
  if (instances) {
    for (auto &&inst : *instances) {
      if (inst->group->sceneGeometries) {
        geometriesInstIEs.push_back(inst->getIE());
        addGeometryInstance(embreeSceneHandleGeometries,
            inst->group->sceneGeometries,
            inst,
            embreeDevice);
      }
      if (inst->group->sceneVolumes) {
        volumesInstIEs.push_back(inst->getIE());
        addGeometryInstance(embreeSceneHandleVolumes,
            inst->group->sceneVolumes,
            inst,
            embreeDevice);
      }
      if (inst->group->sceneClippers) {
        clippersInstIEs.push_back(inst->getIE());
        addGeometryInstance(embreeSceneHandleClippers,
            inst->group->sceneClippers,
            inst,
            embreeDevice);
        numInvertedClippers += inst->group->numInvertedClippers;
      }
    }
  }

  if (embreeSceneHandleGeometries) {
    rtcSetSceneFlags(
        embreeSceneHandleGeometries, static_cast<RTCSceneFlags>(sceneFlags));
    rtcCommitScene(embreeSceneHandleGeometries);
  }
  if (embreeSceneHandleVolumes) {
    rtcSetSceneFlags(
        embreeSceneHandleVolumes, static_cast<RTCSceneFlags>(sceneFlags));
    rtcCommitScene(embreeSceneHandleVolumes);
  }
  if (embreeSceneHandleClippers) {
    rtcSetSceneFlags(embreeSceneHandleClippers,
        static_cast<RTCSceneFlags>(
            sceneFlags | RTC_SCENE_FLAG_CONTEXT_FILTER_FUNCTION));
    rtcCommitScene(embreeSceneHandleClippers);
  }

  const auto numGeometriesInst = geometriesInstIEs.size();
  const auto numVolumesInst = volumesInstIEs.size();
  const auto numClippersInst = clippersInstIEs.size();

  ispc::World_set(getIE(),
      numGeometriesInst ? geometriesInstIEs.data() : nullptr,
      numGeometriesInst,
      numVolumesInst ? volumesInstIEs.data() : nullptr,
      numVolumesInst,
      numClippersInst ? clippersInstIEs.data() : nullptr,
      numClippersInst,
      embreeSceneHandleGeometries,
      embreeSceneHandleVolumes,
      embreeSceneHandleClippers,
      numInvertedClippers);
}

box3f World::getBounds() const
{
  box3f sceneBounds;

  box4f bounds; // NOTE(jda) - Embree expects box4f, NOT box3f...
  if (embreeSceneHandleGeometries) {
    rtcGetSceneBounds(embreeSceneHandleGeometries, (RTCBounds *)&bounds);
    sceneBounds.extend(box3f(vec3f(&bounds.lower[0]), vec3f(&bounds.upper[0])));
  }

  if (embreeSceneHandleVolumes) {
    rtcGetSceneBounds(embreeSceneHandleVolumes, (RTCBounds *)&bounds);
    sceneBounds.extend(box3f(vec3f(&bounds.lower[0]), vec3f(&bounds.upper[0])));
  }

  return sceneBounds;
}

void World::setDevice(RTCDevice device)
{
  embreeDevice = device;
}

OSPTYPEFOR_DEFINITION(World *);

} // namespace ospray
