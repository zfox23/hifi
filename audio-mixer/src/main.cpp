//
//  main.cpp
//  mixer
//
//  Created by Stephen Birarda on 2/1/13.
//  Copyright (c) 2013 High Fidelity, Inc. All rights reserved.
//

#include <iostream>
#include <math.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <errno.h>
#include <fstream>
#include <limits>
#include <signal.h>

#include <glm/gtx/norm.hpp>
#include <glm/gtx/vector_angle.hpp>
#include <AgentList.h>
#include <Agent.h>
#include <AgentTypes.h>
#include <SharedUtil.h>
#include <StdDev.h>
#include <Stk.h>
#include <FreeVerb.h>

#include "InjectedAudioRingBuffer.h"
#include "AvatarAudioRingBuffer.h"
#include <AudioRingBuffer.h>
#include "PacketHeaders.h"

#ifdef _WIN32
#include "Syssocket.h"
#include "Systime.h"
#include <math.h>
#else
#include <sys/time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#endif //_WIN32

const unsigned short MIXER_LISTEN_PORT = 55443;

const short JITTER_BUFFER_MSECS = 12;
const short JITTER_BUFFER_SAMPLES = JITTER_BUFFER_MSECS * (SAMPLE_RATE / 1000.0);

const float BUFFER_SEND_INTERVAL_USECS = (BUFFER_LENGTH_SAMPLES_PER_CHANNEL / SAMPLE_RATE) * 1000000;

const long MAX_SAMPLE_VALUE = std::numeric_limits<int16_t>::max();
const long MIN_SAMPLE_VALUE = std::numeric_limits<int16_t>::min();

void plateauAdditionOfSamples(int16_t &mixSample, int16_t sampleToAdd) {
    long sumSample = sampleToAdd + mixSample;
    
    long normalizedSample = std::min(MAX_SAMPLE_VALUE, sumSample);
    normalizedSample = std::max(MIN_SAMPLE_VALUE, sumSample);
    
    mixSample = normalizedSample;    
}

void attachNewBufferToAgent(Agent *newAgent) {
    if (!newAgent->getLinkedData()) {
        if (newAgent->getType() == AGENT_TYPE_AVATAR) {
            newAgent->setLinkedData(new AvatarAudioRingBuffer());
        } else {
            newAgent->setLinkedData(new InjectedAudioRingBuffer());
        }
    }
}

struct SharedAudioFactors {
    float distanceCoefficient;
    float effectMix;
};

int main(int argc, const char* argv[]) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    
    AgentList* agentList = AgentList::createInstance(AGENT_TYPE_AUDIO_MIXER, MIXER_LISTEN_PORT);
    
    ssize_t receivedBytes = 0;
    
    agentList->linkedDataCreateCallback = attachNewBufferToAgent;
    
    agentList->startSilentAgentRemovalThread();
    agentList->startDomainServerCheckInThread();

    unsigned char* packetData = new unsigned char[MAX_PACKET_SIZE];

    sockaddr* agentAddress = new sockaddr;

    // make sure our agent socket is non-blocking
    agentList->getAgentSocket()->setBlocking(false);
    
    int nextFrame = 0;
    timeval startTime;
    
    unsigned char clientPacket[BUFFER_LENGTH_BYTES_STEREO + sizeof(PACKET_HEADER_MIXED_AUDIO)];
    clientPacket[0] = PACKET_HEADER_MIXED_AUDIO;
    
    int16_t clientSamples[BUFFER_LENGTH_SAMPLES_PER_CHANNEL * 2] = {};
    
    // setup STK for the reverb effect
    const float DISTANCE_REVERB_DAMPING = 0.6f;
    const float DISTANCE_REVERB_ROOM_SIZE = 0.75f;
    const float DISTANCE_REVERB_WIDTH = 0.5f;
    
    gettimeofday(&startTime, NULL);
    
    while (true) {
        for (AgentList::iterator agent = agentList->begin(); agent != agentList->end(); agent++) {
            PositionalAudioRingBuffer* positionalRingBuffer = (PositionalAudioRingBuffer*) agent->getLinkedData();
            
            if (positionalRingBuffer && positionalRingBuffer->shouldBeAddedToMix(JITTER_BUFFER_SAMPLES)) {
                // this is a ring buffer that is ready to go
                // set its flag so we know to push its buffer when all is said and done
                positionalRingBuffer->setWillBeAddedToMix(true);
            }
        }
        
        for (AgentList::iterator agent = agentList->begin(); agent != agentList->end(); agent++) {
            if (agent->getType() == AGENT_TYPE_AVATAR) {
                AvatarAudioRingBuffer* agentRingBuffer = (AvatarAudioRingBuffer*) agent->getLinkedData();
                
                // zero out the client mix for this agent
                memset(clientSamples, 0, sizeof(clientSamples));
                
                const int PHASE_DELAY_AT_90 = 20;
                
                for (AgentList::iterator otherAgent = agentList->begin(); otherAgent != agentList->end(); otherAgent++) {
                    if (((PositionalAudioRingBuffer*) otherAgent->getLinkedData())->willBeAddedToMix()
                        && (otherAgent != agent || (otherAgent == agent && agentRingBuffer->shouldLoopbackForAgent()))) {
                        
                        PositionalAudioRingBuffer* otherAgentBuffer = (PositionalAudioRingBuffer*) otherAgent->getLinkedData();
                        
                        float bearingRelativeAngleToSource = 0.0f;
                        float attenuationCoefficient = 1.0f;
                        int numSamplesDelay = 0;
                        float weakChannelAmplitudeRatio = 1.0f;
                        
                        stk::FreeVerb* otherAgentFreeVerb = NULL;
                        
                        if (otherAgent != agent) {
                            
                            glm::vec3 listenerPosition = agentRingBuffer->getPosition();
                            glm::vec3 relativePosition = otherAgentBuffer->getPosition() - agentRingBuffer->getPosition();
                            glm::quat inverseOrientation = glm::inverse(agentRingBuffer->getOrientation());
                            
                            float distanceSquareToSource = glm::dot(relativePosition, relativePosition);
                            float radius = 0.0f;
                            
                            if (otherAgent->getType() == AGENT_TYPE_AUDIO_INJECTOR) {
                                InjectedAudioRingBuffer* injectedBuffer = (InjectedAudioRingBuffer*) otherAgentBuffer;
                                radius = injectedBuffer->getRadius();
                                attenuationCoefficient *= injectedBuffer->getAttenuationRatio();
                            }
                            
                            if (radius == 0 || (distanceSquareToSource > radius * radius)) {
                                // this is either not a spherical source, or the listener is outside the sphere
                                
                                if (radius > 0) {
                                    // this is a spherical source - the distance used for the coefficient
                                    // needs to be the closest point on the boundary to the source
                                                             
                                    // ovveride the distance to the agent with the distance to the point on the
                                    // boundary of the sphere
                                    distanceSquareToSource -= (radius * radius);
                                    
                                } else {
                                    // calculate the angle delivery for off-axis attenuation
                                    glm::vec3 rotatedListenerPosition = glm::inverse(otherAgentBuffer->getOrientation())
                                        * relativePosition;
                                    
                                    float angleOfDelivery = glm::angle(glm::vec3(0.0f, 0.0f, -1.0f),
                                                                       glm::normalize(rotatedListenerPosition));
                                    
                                    const float MAX_OFF_AXIS_ATTENUATION = 0.2f;
                                    const float OFF_AXIS_ATTENUATION_FORMULA_STEP = (1 - MAX_OFF_AXIS_ATTENUATION) / 2.0f;
                                    
                                    float offAxisCoefficient = MAX_OFF_AXIS_ATTENUATION +
                                        (OFF_AXIS_ATTENUATION_FORMULA_STEP * (angleOfDelivery / 90.0f));
                                    
                                    // multiply the current attenuation coefficient by the calculated off axis coefficient
                                    attenuationCoefficient *= offAxisCoefficient;
                                }
                                
                                glm::vec3 rotatedSourcePosition = inverseOrientation * relativePosition;
                                
                                const float DISTANCE_SCALE = 2.5f;
                                const float GEOMETRIC_AMPLITUDE_SCALAR = 0.3f;
                                const float DISTANCE_LOG_BASE = 2.5f;
                                const float DISTANCE_SCALE_LOG = logf(DISTANCE_SCALE) / logf(DISTANCE_LOG_BASE);
                                
                                // calculate the distance coefficient using the distance to this agent
                                float distanceCoefficient = powf(GEOMETRIC_AMPLITUDE_SCALAR,
                                                           DISTANCE_SCALE_LOG +
                                                           (0.5f * logf(distanceSquareToSource) / logf(DISTANCE_LOG_BASE)) - 1);
                                distanceCoefficient = std::min(1.0f, distanceCoefficient);
                                
                                // multiply the current attenuation coefficient by the distance coefficient
                                attenuationCoefficient *= distanceCoefficient;
                                
                                // project the rotated source position vector onto the XZ plane
                                rotatedSourcePosition.y = 0.0f;
                                
                                // produce an oriented angle about the y-axis
                                bearingRelativeAngleToSource = glm::orientedAngle(glm::vec3(0.0f, 0.0f, -1.0f),
                                                                                  glm::normalize(rotatedSourcePosition),
                                                                                  glm::vec3(0.0f, 1.0f, 0.0f));
                                
                                const float PHASE_AMPLITUDE_RATIO_AT_90 = 0.5;
                                
                                // figure out the number of samples of delay and the ratio of the amplitude
                                // in the weak channel for audio spatialization
                                float sinRatio = fabsf(sinf(glm::radians(bearingRelativeAngleToSource)));
                                numSamplesDelay = PHASE_DELAY_AT_90 * sinRatio;
                                weakChannelAmplitudeRatio = 1 - (PHASE_AMPLITUDE_RATIO_AT_90 * sinRatio);
                            }
                            
                            FreeVerbAgentMap& agentFreeVerbs = agentRingBuffer->getFreeVerbs();
                            FreeVerbAgentMap::iterator freeVerbIterator = agentFreeVerbs.find(otherAgent->getAgentID());
                            
                            if (freeVerbIterator == agentFreeVerbs.end()) {
                                // setup the freeVerb effect for this source for this client
                                otherAgentFreeVerb = agentFreeVerbs[otherAgent->getAgentID()] = new stk::FreeVerb;
                                
                                otherAgentFreeVerb->setDamping(DISTANCE_REVERB_DAMPING);
                                otherAgentFreeVerb->setRoomSize(DISTANCE_REVERB_ROOM_SIZE);
                                otherAgentFreeVerb->setWidth(DISTANCE_REVERB_WIDTH);
                            } else {
                                otherAgentFreeVerb = freeVerbIterator->second;
                            }
                            
                            const float WETNESS_DOUBLING_DISTANCE_FACTOR = 2.0f;
                            const float MAX_REVERB_DISTANCE = 160.0f;
                            
                            // higher value increases wetness more quickly with distance
                            const float WETNESS_CALC_EXPONENT_BASE = 2.0f; 
                            
                            const float MAX_EXPONENT = logf(MAX_REVERB_DISTANCE) / logf(WETNESS_DOUBLING_DISTANCE_FACTOR);
                            const int MAX_EXPONENT_INT = floorf(MAX_EXPONENT);
                            float DISTANCE_REVERB_LOG_REMAINDER = fmodf(MAX_EXPONENT, MAX_EXPONENT_INT);
                            
                            const float DISTANCE_REVERB_MAX_WETNESS = 1.0f;
                            
                            float effectMix = powf(WETNESS_CALC_EXPONENT_BASE,
                                                   (0.5f * logf(distanceSquareToSource) / logf(WETNESS_CALC_EXPONENT_BASE))
                                                   - DISTANCE_REVERB_LOG_REMAINDER);
                            effectMix *= DISTANCE_REVERB_MAX_WETNESS / (powf(WETNESS_DOUBLING_DISTANCE_FACTOR,
                                                                             MAX_EXPONENT_INT));
                            
                            otherAgentFreeVerb->setEffectMix(effectMix);
                        }
                        
                        int16_t* goodChannel = (bearingRelativeAngleToSource > 0.0f)
                            ? clientSamples
                            : clientSamples + BUFFER_LENGTH_SAMPLES_PER_CHANNEL;
                        int16_t* delayedChannel = (bearingRelativeAngleToSource > 0.0f)
                            ? clientSamples + BUFFER_LENGTH_SAMPLES_PER_CHANNEL
                            : clientSamples;
                        
                        int16_t* delaySamplePointer = otherAgentBuffer->getNextOutput() == otherAgentBuffer->getBuffer()
                            ? otherAgentBuffer->getBuffer() + RING_BUFFER_LENGTH_SAMPLES - numSamplesDelay
                            : otherAgentBuffer->getNextOutput() - numSamplesDelay;
                        
                        
                        for (int s = 0; s < BUFFER_LENGTH_SAMPLES_PER_CHANNEL; s++) {
                            if (s < numSamplesDelay) {
                                // pull the earlier sample for the delayed channel
                                int earlierSample = delaySamplePointer[s]
                                    * attenuationCoefficient
                                    * weakChannelAmplitudeRatio;
                                
                                plateauAdditionOfSamples(delayedChannel[s], earlierSample);
                            }
                            
                            int16_t currentSample = otherAgentBuffer->getNextOutput()[s];
                            
                            // apply the STK FreeVerb effect
                            if (otherAgentFreeVerb) {
                                currentSample = otherAgentFreeVerb->tick(currentSample);
                                
                                if (s >= BUFFER_LENGTH_SAMPLES_PER_CHANNEL - PHASE_DELAY_AT_90) {
                                    // there is the possiblity this will be re-used as a delayed sample
                                    // so store the reverbed sample so that is what will be pulled
                                    otherAgentBuffer->getNextOutput()[s] = currentSample;
                                }
                            }
                            
                            currentSample *= attenuationCoefficient;
                            
                            plateauAdditionOfSamples(goodChannel[s], currentSample);
                            
                            if (s + numSamplesDelay < BUFFER_LENGTH_SAMPLES_PER_CHANNEL) {
                                plateauAdditionOfSamples(delayedChannel[s + numSamplesDelay],
                                                         currentSample * weakChannelAmplitudeRatio);
                            }
                        }
                    }
                }
                
                memcpy(clientPacket + sizeof(PACKET_HEADER_MIXED_AUDIO), clientSamples, sizeof(clientSamples));
                agentList->getAgentSocket()->send(agent->getPublicSocket(), clientPacket, sizeof(clientPacket));
            }
        }
        
        // push forward the next output pointers for any audio buffers we used
        for (AgentList::iterator agent = agentList->begin(); agent != agentList->end(); agent++) {
            PositionalAudioRingBuffer* agentBuffer = (PositionalAudioRingBuffer*) agent->getLinkedData();
            if (agentBuffer && agentBuffer->willBeAddedToMix()) {
                agentBuffer->setNextOutput(agentBuffer->getNextOutput() + BUFFER_LENGTH_SAMPLES_PER_CHANNEL);
                
                if (agentBuffer->getNextOutput() >= agentBuffer->getBuffer() + RING_BUFFER_LENGTH_SAMPLES) {
                    agentBuffer->setNextOutput(agentBuffer->getBuffer());
                }
                
                agentBuffer->setWillBeAddedToMix(false);
            }
        }
        
        // pull any new audio data from agents off of the network stack
        while (agentList->getAgentSocket()->receive(agentAddress, packetData, &receivedBytes)) {
            if (packetData[0] == PACKET_HEADER_MICROPHONE_AUDIO_NO_ECHO ||
                packetData[0] == PACKET_HEADER_MICROPHONE_AUDIO_WITH_ECHO) {
                Agent* avatarAgent = agentList->addOrUpdateAgent(agentAddress,
                                                                 agentAddress,
                                                                 AGENT_TYPE_AVATAR,
                                                                 agentList->getLastAgentID());
                
                if (avatarAgent->getAgentID() == agentList->getLastAgentID()) {
                    agentList->increaseAgentID();
                }
                
                agentList->updateAgentWithData(agentAddress, packetData, receivedBytes);
                
                if (std::isnan(((PositionalAudioRingBuffer *)avatarAgent->getLinkedData())->getOrientation().x)) {
                    // kill off this agent - temporary solution to mixer crash on mac sleep
                    avatarAgent->setAlive(false);
                }
            } else if (packetData[0] == PACKET_HEADER_INJECT_AUDIO) {
                Agent* matchingInjector = NULL;
                
                for (AgentList::iterator agent = agentList->begin(); agent != agentList->end(); agent++) {
                    if (agent->getLinkedData()) {
                       
                        InjectedAudioRingBuffer* ringBuffer = (InjectedAudioRingBuffer*) agent->getLinkedData();
                        if (memcmp(ringBuffer->getStreamIdentifier(),
                                   packetData + 1,
                                   STREAM_IDENTIFIER_NUM_BYTES) == 0) {
                            // this is the matching stream, assign to matchingInjector and stop looking
                            matchingInjector = &*agent;
                            break;
                        }
                    }
                }
                
                if (!matchingInjector) {
                    matchingInjector = agentList->addOrUpdateAgent(NULL,
                                                                   NULL,
                                                                   AGENT_TYPE_AUDIO_INJECTOR,
                                                                   agentList->getLastAgentID());
                    agentList->increaseAgentID();
                    
                }
                
                // give the new audio data to the matching injector agent
                agentList->updateAgentWithData(matchingInjector, packetData, receivedBytes);
            }
        }
        
        double usecToSleep = usecTimestamp(&startTime) + (++nextFrame * BUFFER_SEND_INTERVAL_USECS) - usecTimestampNow();
        
        if (usecToSleep > 0) {
            usleep(usecToSleep);
        } else {
            std::cout << "Took too much time, not sleeping!\n";
        }
    }
    
    return 0;
}
