/*
 * SplitNodeGPUMemManager.h
 *
 *  Created on: 16/05/2016
 *      Author: zeyi
 */

#ifndef SPLITNODEGPUMEMMANAGER_H_
#define SPLITNODEGPUMEMMANAGER_H_

#include "../../pureHost/Tree/TreeNode.h"
#include "../../pureHost/UpdateOps/NodeStat.h"

class SNGPUManager
{
public:
	//memory for the tree
	static TreeNode *m_pTreeNode;
	static int m_maxNumofNode;

	//memory for parent node to children ids
	static int *m_pParentId;
	static int *m_pLeftChildId, *m_pRightChildId;

	//memory for new node statistics
	static nodeStat *m_pNewNodeStat;
	static TreeNode *m_pNewSplittableNode;

	//memory for current number of node
	static int *m_pCurNumofNode;

public:
	void allocMemForTree(int maxNumofNode);
	void allocMemForParenChildIdMapping(int maxNumofSplittable);
	void allocMemForNewNode(int maxNumofSplittable);
};


#endif /* SPLITNODEGPUMEMMANAGER_H_ */
