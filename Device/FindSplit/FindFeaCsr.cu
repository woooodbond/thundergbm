/*
 * FindFeaCsr.cu
 *
 *  Created on: Jul 28, 2017
 *      Author: zeyi
 */

#include <thrust/scan.h>
#include <thrust/extrema.h>
#include <thrust/execution_policy.h>

#include "IndexComputer.h"
#include "FindFeaKernel.h"
#include "../Bagging/BagManager.h"
#include "../CSR/BagCsrManager.h"
#include "../Splitter/DeviceSplitter.h"
#include "../Memory/gbdtGPUMemManager.h"
#include "../../SharedUtility/CudaMacro.h"
#include "../../SharedUtility/KernelConf.h"
#include "../../SharedUtility/segmentedMax.h"
#include "../../SharedUtility/segmentedSum.h"
#include "../../SharedUtility/setSegmentKey.h"

#include "../CSR/CsrSplit.h"
#include "../CSR/CsrCompressor.h"
uint numofDenseValue_previous;
void DeviceSplitter::FeaFinderAllNode2(void *pStream, int bagId)
{
	cudaDeviceSynchronize();
	GBDTGPUMemManager manager;
	BagManager bagManager;
	BagCsrManager csrManager(bagManager.m_numFea, bagManager.m_maxNumSplittable, bagManager.m_numFeaValue);
	int numofSNode = bagManager.m_curNumofSplitableEachBag_h[bagId];

	IndexComputer indexComp;
	indexComp.AllocMem(bagManager.m_numFea, numofSNode, bagManager.m_maxNumSplittable);
	
	int maxNumofSplittable = bagManager.m_maxNumSplittable;
	int nNumofFeature = manager.m_numofFea;
	PROCESS_ERROR(nNumofFeature > 0);
	int curNumofNode;
	manager.MemcpyDeviceToHostAsync(bagManager.m_pCurNumofNodeTreeOnTrainingEachBag_d + bagId, &curNumofNode, sizeof(int), pStream);

	if(curNumofNode == 1){
		checkCudaErrors(cudaMemcpy(csrManager.preFvalueInsId, manager.m_pDInsId, sizeof(int) * bagManager.m_numFeaValue, cudaMemcpyDeviceToDevice));
		numofDenseValue_previous = bagManager.m_numFeaValue;//initialise dense value length
	}

	cudaStreamSynchronize((*(cudaStream_t*)pStream));

	//compute index for each feature value
	KernelConf conf;
	int blockSizeLoadGD;
	dim3 dimNumofBlockToLoadGD;
	conf.ConfKernel(bagManager.m_numFeaValue, blockSizeLoadGD, dimNumofBlockToLoadGD);
	int maxNumFeaValueOneNode = -1;
	clock_t csr_len_t = clock();
	if(numofSNode > 1)
	{
		PROCESS_ERROR(nNumofFeature == bagManager.m_numFea);
		clock_t comIdx_start = clock();
		//compute gather index via GPUs
		indexComp.ComputeIdxGPU(numofSNode, maxNumofSplittable, bagId);
		clock_t comIdx_end = clock();
		total_com_idx_t += (comIdx_end - comIdx_start);

		//copy # of feature values of each node
		uint *pTempNumFvalueEachNode = bagManager.m_pNumFvalueEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable;
		uint *pMaxNumFvalueOneNode = thrust::max_element(thrust::device, pTempNumFvalueEachNode, pTempNumFvalueEachNode + numofSNode);
		cudaDeviceSynchronize();
		checkCudaErrors(cudaMemcpy(&maxNumFeaValueOneNode, pMaxNumFvalueOneNode, sizeof(int), cudaMemcpyDeviceToHost));
		indexComp.FreeMem();
		PROCESS_ERROR(bagManager.m_numFeaValue >= csrManager.curNumCsr);
		//split nodes
		csr_len_t = clock();

		if(indexComp.partitionMarker.reservedSize < csrManager.curNumCsr * 8){//make sure enough memory for reuse
			printf("reallocate memory for marker (sn=%d): %u v.s. %u.......\n", numofSNode, indexComp.partitionMarker.reservedSize/8, csrManager.curNumCsr);
			indexComp.partitionMarker.reserveSpace(csrManager.curNumCsr * 8, sizeof(unsigned char));
		}
		uint *pOldCsrLen_d = (uint*)indexComp.partitionMarker.addr;
		unsigned char *pCsrId2Pid = (unsigned char*)(((uint*)indexComp.partitionMarker.addr) + csrManager.curNumCsr);
		checkCudaErrors(cudaMemcpy(pOldCsrLen_d, csrManager.getCsrLen(), sizeof(uint) * csrManager.curNumCsr, cudaMemcpyDeviceToDevice));
		checkCudaErrors(cudaMemset(pCsrId2Pid, (int)-1, sizeof(char) * csrManager.curNumCsr));

		thrust::exclusive_scan(thrust::device, csrManager.getCsrLen(), csrManager.getCsrLen() + csrManager.curNumCsr, csrManager.getMutableCsrStart());

		uint *pCsrNewLen_d = (uint*)(indexComp.histogram_d.addr);
		checkCudaErrors(cudaMemset(pCsrNewLen_d, 0, sizeof(uint) * csrManager.curNumCsr * 2));
		checkCudaErrors(cudaMemset(csrManager.pEachCsrFeaLen, 0, sizeof(uint) * bagManager.m_numFea * numofSNode));
		dim3 dimNumofBlockToCsrLen;
		uint blockSizeCsrLen = 128;
		dimNumofBlockToCsrLen.x = (numofDenseValue_previous + blockSizeCsrLen - 1) / blockSizeCsrLen;
		newCsrLenFvalue<<<dimNumofBlockToCsrLen, blockSizeCsrLen, blockSizeCsrLen * sizeof(uint)>>>(
				csrManager.preFvalueInsId, numofDenseValue_previous,
				bagManager.m_pInsIdToNodeIdEachBag + bagId * bagManager.m_numIns,
				bagManager.m_pPreMaxNid_h[bagId], csrManager.getCsrStart(),
				csrManager.getCsrFvalue(), csrManager.curNumCsr,
				csrManager.pEachCsrFeaStartPos, bagManager.m_pPreNumSN_h[bagId],
				bagManager.m_numFea, csrManager.getCsrKey(), pCsrNewLen_d, pCsrId2Pid);

		GETERROR("after newCsrLenFvalue");
		LoadFvalueInsId<<<dimNumofBlockToLoadGD, blockSizeLoadGD>>>(
						bagManager.m_numIns, manager.m_pDInsId, csrManager.preFvalueInsId, bagManager.m_pIndicesEachBag_d, bagManager.m_numFeaValue);
		GETERROR("after LoadFvalueInsId");

		real *pCsrFvalueSpare = (real*)(((int*)indexComp.histogram_d.addr) + csrManager.curNumCsr * 2);//reuse memory

		int blockSizeFillFvalue;
		dim3 dimNumBlockToFillFvalue;
		conf.ConfKernel(csrManager.curNumCsr, blockSizeFillFvalue, dimNumBlockToFillFvalue);
		fillFvalue<<<dimNumBlockToFillFvalue, blockSizeFillFvalue>>>(csrManager.getCsrFvalue(), csrManager.curNumCsr, csrManager.pEachCsrFeaStartPos,
				   bagManager.m_pPreNumSN_h[bagId], bagManager.m_numFea, csrManager.getCsrKey(), pOldCsrLen_d, pCsrId2Pid,
				   pCsrFvalueSpare, pCsrNewLen_d, csrManager.pEachCsrFeaLen);
		GETERROR("after fillFvalue");
		//compute number of CSR in each node
		checkCudaErrors(cudaMemset(csrManager.pEachNodeSizeInCsr, 0, sizeof(uint) * bagManager.m_maxNumSplittable));
		dim3 dimNumSeg;
		dimNumSeg.x = numofSNode;
		uint blockSize = 128;
		segmentedSum<<<dimNumSeg, blockSize, blockSize * sizeof(uint)>>>(csrManager.pEachCsrFeaLen, bagManager.m_numFea, csrManager.pEachNodeSizeInCsr);
		GETERROR("after segmentedSum");

		int blockSizeLoadCsrLen;
		dim3 dimNumofBlockToLoadCsrLen;
		conf.ConfKernel(csrManager.curNumCsr * 2, blockSizeLoadCsrLen, dimNumofBlockToLoadCsrLen);
		uint *pCsrMarker = (uint*)indexComp.partitionMarker.addr;
		checkCudaErrors(cudaMemset(pCsrMarker, 0, sizeof(uint) * csrManager.curNumCsr * 2));
		map2One<<<dimNumofBlockToLoadCsrLen, blockSizeLoadCsrLen>>>(pCsrNewLen_d, csrManager.curNumCsr * 2, pCsrMarker);
		GETERROR("after map2One");
		thrust::inclusive_scan(thrust::device, pCsrMarker, pCsrMarker + csrManager.curNumCsr * 2, pCsrMarker);
		cudaDeviceSynchronize();
		uint previousNumCsr = csrManager.curNumCsr;
		checkCudaErrors(cudaMemcpy(&csrManager.curNumCsr, pCsrMarker + csrManager.curNumCsr * 2 - 1, sizeof(uint), cudaMemcpyDefault));

		checkCudaErrors(cudaMemset(csrManager.getMutableCsrLen(), 0, sizeof(uint) * csrManager.curNumCsr));
		loadDenseCsr<<<dimNumofBlockToLoadCsrLen, blockSizeLoadCsrLen>>>(pCsrFvalueSpare, pCsrNewLen_d,
				previousNumCsr * 2, csrManager.curNumCsr, pCsrMarker,
				csrManager.getMutableCsrFvalue(), csrManager.getMutableCsrLen());
		GETERROR("after loadDenseCsr");
		thrust::exclusive_scan(thrust::device, csrManager.pEachCsrFeaLen, csrManager.pEachCsrFeaLen + numofSNode * bagManager.m_numFea, csrManager.pEachCsrFeaStartPos);

		thrust::exclusive_scan(thrust::device, csrManager.pEachNodeSizeInCsr, csrManager.pEachNodeSizeInCsr + numofSNode, csrManager.pEachCsrNodeStartPos);
		numofDenseValue_previous = thrust::reduce(thrust::device, pTempNumFvalueEachNode, pTempNumFvalueEachNode + numofSNode);//number of dense fvalues.
		uint *pCsrStartCurRound = (uint*)indexComp.partitionMarker.addr;
		thrust::exclusive_scan(thrust::device, csrManager.getCsrLen(), csrManager.getCsrLen() + csrManager.curNumCsr, pCsrStartCurRound);
		PROCESS_ERROR(csrManager.curNumCsr <= bagManager.m_numFeaValue);
		cudaDeviceSynchronize();
	}
	else
	{
		clock_t start_gd = clock();
		cudaStreamSynchronize((*(cudaStream_t*)pStream));
		clock_t end_gd = clock();
		total_fill_gd_t += (end_gd - start_gd);

		clock_t comIdx_start = clock();
		//copy # of feature values of a node
		manager.MemcpyHostToDeviceAsync(&manager.m_numFeaValue, bagManager.m_pNumFvalueEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable,
										sizeof(uint), pStream);
		//copy feature value start position of each node
		manager.MemcpyDeviceToDeviceAsync(manager.m_pFeaStartPos, bagManager.m_pFvalueStartPosEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable,
									 	 sizeof(uint), pStream);
		//copy each feature start position in each node
		manager.MemcpyDeviceToDeviceAsync(manager.m_pFeaStartPos, bagManager.m_pEachFeaStartPosEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea,
										sizeof(uint) * nNumofFeature, pStream);
		//copy # of feature values of each feature in each node
		manager.MemcpyDeviceToDeviceAsync(manager.m_pDNumofKeyValue, bagManager.m_pEachFeaLenEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea,
									    sizeof(int) * nNumofFeature, pStream);

		maxNumFeaValueOneNode = manager.m_numFeaValue;
		clock_t comIdx_end = clock();
		total_com_idx_t += (comIdx_end - comIdx_start);
		//###### compress
		cudaDeviceSynchronize();
		CsrCompressor compressor;
		csrManager.curNumCsr = compressor.totalOrgNumCsr;
		compressor.CsrCompression(csrManager.curNumCsr, csrManager.pEachCsrFeaStartPos, csrManager.pEachCsrFeaLen,
								  csrManager.pEachNodeSizeInCsr, csrManager.pEachCsrNodeStartPos, csrManager.getMutableCsrFvalue(), csrManager.getMutableCsrLen());
	}
	//need to compute for every new tree
	if(indexComp.histogram_d.reservedSize < csrManager.curNumCsr * 4){//make sure enough memory for reuse
		printf("reallocate memory for histogram (sn=%u): %u v.s. %u.......\n", numofSNode, indexComp.numIntMem, csrManager.curNumCsr * 6);
		indexComp.histogram_d.reserveSpace(csrManager.curNumCsr * 4, sizeof(uint));
	}
	cudaDeviceSynchronize();
	double *pGD_d = (double*)indexComp.histogram_d.addr;//reuse memory; must be here, as curNumCsr may change in different level.
	real *pHess_d = (real*)(((uint*)indexComp.histogram_d.addr) + csrManager.curNumCsr * 2);//reuse memory
	real *pGain_d = (real*)(((uint*)indexComp.histogram_d.addr) + csrManager.curNumCsr * 3);
	checkCudaErrors(cudaMemset(pGD_d, 0, sizeof(double) * csrManager.curNumCsr));
	checkCudaErrors(cudaMemset(pHess_d, 0, sizeof(real) * csrManager.curNumCsr));
	dim3 dimNumofBlockForGD;
	dimNumofBlockForGD.x = csrManager.curNumCsr;
	uint blockSizeForGD = 64;
	uint sharedMemSizeForGD = blockSizeForGD * (sizeof(double) + sizeof(real));
	const uint *pCsrStartPos_d;
	if(numofSNode == 1)
		pCsrStartPos_d = CsrCompressor::pCsrStart_d;
	else
		pCsrStartPos_d = (uint*)indexComp.partitionMarker.addr;
	ComputeGDHess<<<dimNumofBlockForGD, blockSizeForGD, sharedMemSizeForGD>>>(csrManager.getCsrLen(), pCsrStartPos_d,
			bagManager.m_pInsGradEachBag + bagId * bagManager.m_numIns,
			bagManager.m_pInsHessEachBag + bagId * bagManager.m_numIns,
			csrManager.preFvalueInsId, pGD_d, pHess_d);
	cudaDeviceSynchronize();
	GETERROR("after ComputeGD");
	clock_t csr_len_end = clock();
	total_csr_len_t += (csr_len_end - csr_len_t);

	//cout << "prefix sum" << endl;
	int numSeg = bagManager.m_numFea * numofSNode;
	clock_t start_scan = clock();

	//construct keys for exclusive scan
	checkCudaErrors(cudaMemset(csrManager.getMutableCsrKey(), -1, sizeof(uint) * csrManager.curNumCsr));

	//set keys by GPU
	uint maxSegLen = 0;
	uint *pMaxLen = thrust::max_element(thrust::device, csrManager.pEachCsrFeaLen, csrManager.pEachCsrFeaLen + numSeg);
	cudaDeviceSynchronize();
	checkCudaErrors(cudaMemcpyAsync(&maxSegLen, pMaxLen, sizeof(uint), cudaMemcpyDeviceToHost, (*(cudaStream_t*)pStream)));
	cudaStreamSynchronize((*(cudaStream_t*)pStream));

	dim3 dimNumofBlockToSetKey;
	dimNumofBlockToSetKey.x = numSeg;
	uint blockSize = 128;
	dimNumofBlockToSetKey.y = (maxSegLen + blockSize - 1) / blockSize;
	SetKey<<<numSeg, blockSize, sizeof(uint) * 2, (*(cudaStream_t*)pStream)>>>
			(csrManager.pEachCsrFeaStartPos, csrManager.pEachCsrFeaLen, csrManager.getMutableCsrKey());
	cudaStreamSynchronize((*(cudaStream_t*)pStream));

	//compute prefix sum for gd and hess (more than one arrays)
	thrust::inclusive_scan_by_key(thrust::device, csrManager.getCsrKey(), csrManager.getCsrKey() + csrManager.curNumCsr, pGD_d, pGD_d);//in place prefix sum
	thrust::inclusive_scan_by_key(thrust::device, csrManager.getCsrKey(), csrManager.getCsrKey() + csrManager.curNumCsr, pHess_d, pHess_d);
	clock_t end_scan = clock();
	total_scan_t += (end_scan - start_scan);

	//compute gain; default to left or right
	bool *default2Right = (bool*)indexComp.partitionMarker.addr;
	checkCudaErrors(cudaMemset(default2Right, 0, sizeof(bool) * csrManager.curNumCsr));//this is important (i.e. initialisation)
	checkCudaErrors(cudaMemset(pGain_d, 0, sizeof(real) * csrManager.curNumCsr));

//	cout << "compute gain" << endl;
	uint test = thrust::reduce(thrust::device, csrManager.pEachCsrFeaLen, csrManager.pEachCsrFeaLen + numSeg);
	clock_t start_comp_gain = clock();
	int blockSizeComGain;
	dim3 dimNumofBlockToComGain;
	conf.ConfKernel(csrManager.curNumCsr, blockSizeComGain, dimNumofBlockToComGain);
	cudaDeviceSynchronize();
	GETERROR("before ComputeGainDense");
	ComputeGainDense<<<dimNumofBlockToComGain, blockSizeComGain, 0, (*(cudaStream_t*)pStream)>>>(
											bagManager.m_pSNodeStatEachBag + bagId * bagManager.m_maxNumSplittable,
											bagManager.m_pPartitionId2SNPosEachBag + bagId * bagManager.m_maxNumSplittable,
											DeviceSplitter::m_lambda, pGD_d, pHess_d, csrManager.getCsrFvalue(),
											csrManager.curNumCsr, csrManager.pEachCsrFeaStartPos, csrManager.pEachCsrFeaLen, csrManager.getCsrKey(), bagManager.m_numFea,
											pGain_d, default2Right);
	cudaStreamSynchronize((*(cudaStream_t*)pStream));
	GETERROR("after ComputeGainDense");

	//change the gain of the first feature value to 0
	int blockSizeFirstGain;
	dim3 dimNumofBlockFirstGain;
	conf.ConfKernel(numSeg, blockSizeFirstGain, dimNumofBlockFirstGain);
	FirstFeaGain<<<dimNumofBlockFirstGain, blockSizeFirstGain, 0, (*(cudaStream_t*)pStream)>>>(
			csrManager.pEachCsrFeaStartPos, numSeg, pGain_d, csrManager.curNumCsr);

	//	cout << "searching" << endl;
	cudaDeviceSynchronize();
	clock_t start_search = clock();
	real *pMaxGain_d;
	uint *pMaxGainKey_d;
	checkCudaErrors(cudaMalloc((void**)&pMaxGain_d, sizeof(real) * numofSNode));
	checkCudaErrors(cudaMalloc((void**)&pMaxGainKey_d, sizeof(uint) * numofSNode));
	checkCudaErrors(cudaMemset(pMaxGainKey_d, -1, sizeof(uint) * numofSNode));
	//compute # of blocks for each node
	uint *pMaxNumFvalueOneNode = thrust::max_element(thrust::device, csrManager.pEachNodeSizeInCsr, csrManager.pEachNodeSizeInCsr + numofSNode);
	checkCudaErrors(cudaMemcpy(&maxNumFeaValueOneNode, pMaxNumFvalueOneNode, sizeof(int), cudaMemcpyDeviceToHost));
	SegmentedMax(maxNumFeaValueOneNode, numofSNode, csrManager.pEachNodeSizeInCsr, csrManager.pEachCsrNodeStartPos,
				 pGain_d, pStream, pMaxGain_d, pMaxGainKey_d);

	//find the split value and feature
	FindSplitInfo<<<1, numofSNode, 0, (*(cudaStream_t*)pStream)>>>(
										 csrManager.pEachCsrFeaStartPos,
										 csrManager.pEachCsrFeaLen,
										 csrManager.getCsrFvalue(),
										 pMaxGain_d, pMaxGainKey_d,
										 bagManager.m_pPartitionId2SNPosEachBag + bagId * bagManager.m_maxNumSplittable, nNumofFeature,
					  	  	  	  	  	 bagManager.m_pSNodeStatEachBag + bagId * bagManager.m_maxNumSplittable,
					  	  	  	  	  	 pGD_d, pHess_d,
					  	  	  	  	  	 default2Right, csrManager.getCsrKey(),
					  	  	  	  	  	 bagManager.m_pBestSplitPointEachBag + bagId * bagManager.m_maxNumSplittable,
					  	  	  	  	  	 bagManager.m_pRChildStatEachBag + bagId * bagManager.m_maxNumSplittable,
					  	  	  	  	  	 bagManager.m_pLChildStatEachBag + bagId * bagManager.m_maxNumSplittable);
	cudaStreamSynchronize((*(cudaStream_t*)pStream));
	checkCudaErrors(cudaFree(pMaxGain_d));
	checkCudaErrors(cudaFree(pMaxGainKey_d));
}
