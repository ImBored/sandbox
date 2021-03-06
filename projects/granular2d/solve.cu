#include "solve.h"

#include <iostream>
#include <thrust/sort.h>

#ifdef _WIN32
typedef unsigned int uint32_t;
//typedef unsigned short uint32_t;
#endif

using namespace std;

#define PROFILE 1
#define USE_GRID 1
#define USE_BOX_PRUNING 0

#define kRadius 0.05f
#define kMaxRadius (kRadius)// + 0.2f*kRadius)
#define kInvCellEdge (0.5f/kMaxRadius)

#if USE_GRID
typedef uint32_t CellId;
#else
typedef float CellId;
#endif

struct GrainSystem
{
public:
	
	float2* mPositions;
	float2* mVelocities;
	float* mRadii;
	
	float2* mSortedPositions;
	float2* mSortedVelocities;
	float* mSortedRadii;

	float2* mNewVelocities;

	uint32_t* mCellStarts;
	uint32_t* mCellEnds;
	CellId* mCellIds;
	uint32_t* mIndices;

	uint32_t mNumGrains;
	GrainParams mParams;
};

#if PROFILE

struct CudaTimer
{
	CudaTimer(const char* name, cudaEvent_t start, cudaEvent_t stop, float& timer) : mTimer(timer), mName(name), mStart(start), mStop(stop)
	{
		cudaEventRecord(mStart, 0);
	}
	
	~CudaTimer()
	{
		cudaEventRecord(mStop, 0);
		cudaEventSynchronize(mStop);
		
		float elapsedTime;
		cudaEventElapsedTime(&elapsedTime, mStart, mStop);
		
		mTimer += elapsedTime;

		//cout << mName << " took: " << elapsedTime << endl;
	}
	
	float& mTimer;
	cudaEvent_t mStart;
	cudaEvent_t mStop;
	const char* mName;
};

#else
struct CudaTimer
{
	CudaTimer(const char*, cudaEvent_t, cudaEvent_t, float& ) {}
};
#endif

void SortCellIndices(uint32_t* cellIds, uint32_t* particleIndices, uint32_t numGrains);
void SortCellIndices(float* cellIds, uint32_t* particleIndices, uint32_t numGrains);

__device__ inline float sqr(float x) { return x*x; }


// calculate collision impulse
__device__ inline float2 CollisionImpulse(float2 va, float2 vb, float ma, float mb, float2 n, float d, float baumgarte, float friction, float overlap)
{
	// calculate relative velocity
	float2 vd = vb-va;
	
	// calculate relative normal velocity
	float vn = dot(vd, n);
	
	float2 j = make_float2(0.0f, 0.0f);
	
	//if (vn < 0.0f)
	vn = min(vn, 0.0f);

	{
		// calculate relative tangential velocity
		float2 vt = vd - n*vn;	
		float rcpvt = rsqrtf(dot(vt, vt) + 0.001f);

		// position bias
		float bias = baumgarte*min(d+overlap, 0.0f);

		float2 jn = -(vn + bias)*n;
		float2 jt = max(friction*vn*rcpvt, -0.5f)*vt;

		// total mass 
		float msum = ma + mb;
	
		// normal impulse
		j = (jn + jt)*mb/msum;
	}
	
	return j;
}

#if USE_GRID

const uint32_t kGridDim = 128;

// transform a world space coordinate into cell coordinate
__device__ inline uint32_t GridCoord(float x, float invCellEdge)
{
	// offset to handle negative numbers
	float l = x+100.0f;
	
	uint32_t c = (uint32_t)(floorf(l*invCellEdge));
	return c;
}

/*

__device__ inline uint32_t GridHash(int x, int y)
{	
	uint32_t cx = x & (kGridDim-1);
	uint32_t cy = y & (kGridDim-1);
	
	return cy*kGridDim + cx;
}
*/
__device__ inline uint32_t GridHash(int x, int y)
{
	const uint32_t p1 = 73856093;   // some large primes
	const uint32_t p2 = 19349663;
		
	uint32_t n = x*p1 ^ y*p2;
	return n&(kGridDim*kGridDim-1);
}


__global__ void CreateCellIndices(const float2* positions, uint32_t* cellIds, uint32_t* particleIndices)
{
	uint32_t i = blockIdx.x*blockDim.x + threadIdx.x;

	float2 p = positions[i];
	
	cellIds[i] = GridHash(GridCoord(p.x, kInvCellEdge), GridCoord(p.y, kInvCellEdge));
	particleIndices[i] = i;	
}

__global__ void CreateGrid(const uint32_t* cellIds, uint32_t* cellStarts, uint32_t* cellEnds, uint32_t numGrains)
{	
	uint32_t i = blockIdx.x*blockDim.x + threadIdx.x;
	
	// scan the particle-cell array to find the start and end
	uint32_t c = cellIds[i];
	
	if (i == 0)
	{
		cellStarts[c] = i;
	}
	else
	{
		uint32_t p = cellIds[i-1];

		if (c != p)
		{
			cellStarts[c] = i;
			cellEnds[p] = i;
		}
	}
	
	if (i == numGrains-1)
	{
		cellEnds[c] = i+1;
	}
}



__device__ inline float2 CollideCell(int index, int cx, int cy, const uint32_t* cellStarts, const uint32_t* cellEnds, const uint32_t* indices,
				 const float2* positions, const float2* velocities, const float* radii, float2 x, float2 v, float r, float baumgarte, float friction, float overlap)
{
	float2 j = make_float2(0.0f, 0.0f);
	
	uint32_t cellIndex = GridHash(cx, cy);
	uint32_t cellStart = cellStarts[cellIndex];
	uint32_t cellEnd = cellEnds[cellIndex];
	
	for (int i=cellStart; i < cellEnd; ++i)
	{
		uint32_t particleIndex = i;//indices[i];
		
		if (particleIndex != index)
		{
			// distance to sphere
			float2 t = x - positions[particleIndex];
			
			float d = dot(t, t);
			float rsum = r + radii[particleIndex];
			float mtd = d - sqr(rsum);
			
			if (mtd < 0.0f)
			{
				float2 n = make_float2(0.0f, 1.0f);
				
				if (d > 0.0f)
				{
					d = sqrtf(d);
					n = t / d;
				}
				
				j += CollisionImpulse(velocities[particleIndex], v, 1.0f, 1.0f, n, d-rsum, baumgarte, friction, overlap);
			}
		}		
	}
	
	return j;
}


#endif

#if USE_BOX_PRUNING

__global__ void CreateCellIndices(const float2* positions, float* cellIds, uint32_t* particleIndices)
{
	uint32_t i = blockIdx.x*blockDim.x + threadIdx.x;

	cellIds[i] = positions[i].x;	
	particleIndices[i] = i;	
}

#endif


__global__ void ReorderParticles(const float2* positions, const float2* velocities, const float* radii, float2* sortedPositions, float2* sortedVelocities, float* sortedRadii, const uint32_t* indices)
{
	uint32_t i = blockIdx.x*blockDim.x + threadIdx.x;
	
	int originalIndex = indices[i];

	sortedPositions[i] = positions[originalIndex];
	sortedVelocities[i] = velocities[originalIndex];
	sortedRadii[i] = radii[originalIndex];
}


__global__ void Collide(const float2* positions, const float2* velocities, const float* radii, const uint32_t* cellStarts, const uint32_t* cellEnds, const uint32_t* indices,
						float2* newVelocities, int numGrains, GrainParams params, float dt)
{
	const int index = blockIdx.x*blockDim.x + threadIdx.x;
		
	const float2 x = positions[index];
	const float2 v = velocities[index];
	const float  r = radii[index];

	float2 vd = make_float2(0.0f, 0.0f);

#if USE_GRID

	// collide particles
	int cx = GridCoord(x.x, kInvCellEdge);
	int cy = GridCoord(x.y, kInvCellEdge);
	
	for (int j=cy-1; j <= cy+1; ++j)
	{
		for (int i=cx-1; i <= cx+1; ++i)
		{
			vd += CollideCell(index, i, j, cellStarts, cellEnds, indices, positions, velocities, radii, x, v, r, params.mBaumgarte, params.mFriction, params.mOverlap);
		}
	}

#endif

#if USE_BOX_PRUNING

	// walk forward along the list of neighbouring particles
	int i=index+1;

	float maxCoord = x.x + 2.0f*kMaxRadius;
	float minCoord = x.x - 2.0f*kMaxRadius;

	while (i < numGrains)
	{
		if (positions[i].x > maxCoord)
			break;

		// distance to sphere
		float2 t = x - positions[i];
			
		float d = dot(t, t);
		float rsum = r + radii[i];
		float mtd = d - sqr(rsum);
			
		if (mtd < 0.0f)
		{
			float2 n = make_float2(0.0f, 1.0f);
				
			if (d > 0.0f)
			{
				d = sqrtf(d);
				n = t / d;
			}
				
			vd += CollisionImpulse(velocities[i], v, 1.0f, 1.0f, n, d-rsum, params.mBaumgarte, params.mFriction, params.mOverlap);
		}

		++i;
	}
	
	// walk backward along the list of neighbouring particles
	i=index-1;

	while (i >= 0)
	{
		if (positions[i].x < minCoord)
			break;

		// distance to sphere
		float2 t = x - positions[i];
			
		float d = dot(t, t);
		float rsum = r + radii[i];
		float mtd = d - sqr(rsum);
			
		if (mtd < 0.0f)
		{
			float2 n = make_float2(0.0f, 1.0f);
				
			if (d > 0.0f)
			{
				d = sqrtf(d);
				n = t / d;
			}
				
			vd += CollisionImpulse(velocities[i], v, 1.0f, 1.0f, n, d-rsum, params.mBaumgarte, params.mFriction, params.mOverlap);
		}

		--i;
	}
	
	
#endif

	// collide planes
	for (int i=0; i < params.mNumPlanes; ++i)
	{
		float3 p = params.mPlanes[i];
						
		// distance to plane
		float d = x.x*p.x + x.y*p.y - p.z;
			
		float mtd = d - r;
			
		if (mtd < 0.0f)
		{
			vd += CollisionImpulse(make_float2(0.0f, 0.0f), v, 0.0f, 1.0f, make_float2(p.x, p.y), mtd, params.mBaumgarte, 0.9f, params.mOverlap);
		}
	}
	
	// write back velocity
	newVelocities[index] = v + vd;
}

__global__ void IntegrateForce(float2* velocities, float2 gravity, float damp, float dt)
{
	int index = blockIdx.x*blockDim.x + threadIdx.x;

	velocities[index] += (gravity - damp*velocities[index])*dt;
}


__global__ void IntegrateVelocity(float2* positions, float2* velocities, const float2* newVelocities, float dt)
{
	int index = blockIdx.x*blockDim.x + threadIdx.x;

	// x += v*dt
	velocities[index] = newVelocities[index];
	positions[index] += velocities[index]*dt; //+ 0.5f*make_float2(0.0f, -9.8f)*dt*dt;
}

__global__ void PrintCellCounts(uint32_t* cellStarts, uint32_t* cellEnds)
{
	int index = blockIdx.x*blockDim.x + threadIdx.x;

	printf("%d\n", cellEnds[index]-cellStarts[index]);

}

//------------------------------------------------------------------


GrainSystem* grainCreateSystem(int numGrains)
{
	GrainSystem* s = new GrainSystem();
	
	s->mNumGrains = numGrains;
	
	cudaMalloc(&s->mPositions, numGrains*sizeof(float2));
	cudaMalloc(&s->mVelocities, numGrains*sizeof(float2));
	cudaMalloc(&s->mNewVelocities, numGrains*sizeof(float2));
	cudaMalloc(&s->mRadii, numGrains*sizeof(float));
	
	cudaMalloc(&s->mSortedPositions, numGrains*sizeof(float2));
	cudaMalloc(&s->mSortedVelocities, numGrains*sizeof(float2));
	cudaMalloc(&s->mSortedRadii, numGrains*sizeof(float));

	// grid
#if USE_GRID
	cudaMalloc(&s->mCellStarts, kGridDim*kGridDim*sizeof(uint32_t));
	cudaMalloc(&s->mCellEnds, kGridDim*kGridDim*sizeof(uint32_t));
#endif

	cudaMalloc(&s->mCellIds, numGrains*sizeof(uint32_t));
	cudaMalloc(&s->mIndices, numGrains*sizeof(uint32_t));
	
	return s;
}

void grainDestroySystem(GrainSystem* s)
{
	cudaFree(s->mPositions);
	cudaFree(s->mVelocities);
	cudaFree(s->mNewVelocities);
	cudaFree(s->mRadii);	
	
	cudaFree(s->mSortedPositions);
	cudaFree(s->mSortedVelocities);
	cudaFree(s->mSortedRadii);	
	
#if USE_GRID
	cudaFree(s->mCellStarts);
	cudaFree(s->mCellEnds);
#endif
	cudaFree(s->mCellIds);
	cudaFree(s->mIndices);

	delete s;
}

void grainSetPositions(GrainSystem* s, float* p, int n)
{
	cudaMemcpy(&s->mPositions[0], p, sizeof(float2)*n, cudaMemcpyHostToDevice);
}

void grainSetVelocities(GrainSystem* s, float* v, int n)
{
	cudaMemcpy(&s->mVelocities[0], v, sizeof(float2)*n, cudaMemcpyHostToDevice);	
}

void grainSetRadii(GrainSystem* s, float* r)
{
	cudaMemcpy(&s->mRadii[0], r, sizeof(float)*s->mNumGrains, cudaMemcpyHostToDevice);
}

void grainGetPositions(GrainSystem* s, float* p)
{
	cudaMemcpy(p, &s->mPositions[0], sizeof(float2)*s->mNumGrains, cudaMemcpyDeviceToHost);
}

void grainGetVelocities(GrainSystem* s, float* v)
{
	cudaMemcpy(v, &s->mVelocities[0], sizeof(float2)*s->mNumGrains, cudaMemcpyDeviceToHost);
}

void grainGetRadii(GrainSystem* s, float* r)
{
	cudaMemcpy(r, &s->mRadii[0], sizeof(float)*s->mNumGrains, cudaMemcpyDeviceToHost);
}

void grainSetParams(GrainSystem* s, GrainParams* params)
{
	//cudaMemcpy(s->mParams, params, sizeof(GrainParams), cudaMemcpyHostToDevice);
	s->mParams = *params;
}

void grainUpdateSystem(GrainSystem* s, float dt, int iterations, GrainTimers* timers)
{
	dt /= iterations;
	
	const int kNumThreadsPerBlock = 128;
	const int kNumBlocks = s->mNumGrains / kNumThreadsPerBlock;

	GrainParams params = s->mParams;
	params.mBaumgarte /= dt;
	
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	for (int i=0; i < iterations; ++i)
	{
		{
			CudaTimer timer("CreateCellIndices", start, stop, timers->mCreateCellIndices);
			
			CreateCellIndices<<<kNumBlocks, kNumThreadsPerBlock>>>(s->mPositions, s->mCellIds, s->mIndices);
		}

		{ 
			CudaTimer timer("SortCellIndices", start, stop, timers->mSortCellIndices);
			
			SortCellIndices(s->mCellIds, s->mIndices, s->mNumGrains);
		}

#if USE_GRID
		{
			CudaTimer timer("CreateGrid", start, stop, timers->mCreateGrid);
			
			cudaMemset(s->mCellStarts, 0, sizeof(uint32_t)*kGridDim*kGridDim);
			cudaMemset(s->mCellEnds, 0, sizeof(uint32_t)*kGridDim*kGridDim);

			CreateGrid<<<kNumBlocks, kNumThreadsPerBlock>>>(s->mCellIds, s->mCellStarts, s->mCellEnds, s->mNumGrains);
		}
#endif

		{
			CudaTimer timer("ReorderParticles", start, stop, timers->mReorder);

			ReorderParticles<<<kNumBlocks, kNumThreadsPerBlock>>>(s->mPositions, s->mVelocities, s->mRadii, s->mSortedPositions, s->mSortedVelocities, s->mSortedRadii, s->mIndices);
		}
		
		//PrintCellCounts<<<kGridDim*kGridDim/kNumThreadsPerBlock, kNumThreadsPerBlock>>>(s->mCellStarts, s->mCellEnds);

		{
			float t;
			CudaTimer timer("Integrate Force", start, stop, t);

			IntegrateForce<<<kNumBlocks, kNumThreadsPerBlock>>>(s->mSortedVelocities, s->mParams.mGravity, s->mParams.mDamp, dt);
		}

		{
			CudaTimer timer("Collide", start, stop, timers->mCollide);

			Collide<<<kNumBlocks, kNumThreadsPerBlock>>>(s->mSortedPositions, s->mSortedVelocities, s->mSortedRadii, s->mCellStarts, s->mCellEnds, s->mIndices, s->mNewVelocities, s->mNumGrains, params, dt);
		}

		{
			CudaTimer timer("Integrate", start, stop, timers->mIntegrate);
			
			IntegrateVelocity<<<kNumBlocks, kNumThreadsPerBlock>>>(s->mSortedPositions, s->mSortedVelocities, s->mNewVelocities, dt); 
		}
	
		swap(s->mSortedPositions, s->mPositions);
		swap(s->mSortedVelocities, s->mVelocities);
		swap(s->mSortedRadii, s->mRadii);

	}		
	
	cudaEventDestroy(start);
	cudaEventDestroy(stop);
}

