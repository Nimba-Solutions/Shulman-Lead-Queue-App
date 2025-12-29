/**
 * Data processing utilities for Lead Queue
 * Handles queue data processing, filtering, and state management
 */
import { SharedUtils } from 'c/sharedUtils';

export class DataProcessor {
    
    constructor(component) {
        this.component = component;
    }

    /**
     * Process queue response data from server
     */
    processQueueResponse(data) {
        // Validate data structure
        if (!data || typeof data !== 'object') {
            console.error('Invalid data structure received:', data);
            this.resetToEmptyState();
            return;
        }
        
        // Safe assignment with fallbacks - store original stats and keep them fixed
        const stats = data.stats ? { ...data.stats } : SharedUtils.getDefaultStats();
        this.component.originalStats = stats;
        // queueStats should always show original values, never update with filters
        this.component.queueStats = { ...this.component.originalStats };
        const listTotalRecords = Number.isFinite(data.listTotalRecords)
            ? data.listTotalRecords
            : this.component.originalStats.totalRecords;
        this.component.listTotalRecords = listTotalRecords;
        this.component.filterOptions = data.filters || { statusOptions: [], caseTypeOptions: [] };
        this.component.tileStatusGroups = data.tileStatusGroups || {};
        
        // Validate records array
        if (!Array.isArray(data.records)) {
            console.error('Records is not an array:', data.records);
            this.component.records = [];
            return;
        }
        
        // Store original data for filter state management
        const pageSize = this.component.pageSize || 50;
        const currentPage = this.component.currentPage || 1;
        const pageOffset = (currentPage - 1) * pageSize;
        this.component.originalRecords = data.records
            .filter(queueRecord => queueRecord && (queueRecord.record || queueRecord.recordId)) // Filter out invalid entries
            .map((queueRecord, index) => {
                const record = queueRecord.record || {};
                const originalRecordId = queueRecord.recordId || record.Id;
                if (!originalRecordId) {
                    return null;
                }
                const displayName = queueRecord.displayName || record.litify_pm__Display_Name__c || record.Name || 'Unknown';
                const referredByName = queueRecord.referredByName || record.Referred_By_Name__c || '';
                const status = queueRecord.status || record.litify_pm__Status__c || '';
                const caseType = queueRecord.caseType || record.Queue_Case_Type__c || '';
                const qualificationStatus = queueRecord.qualificationStatus || record.Qualification_Status__c || '';
                const callAtDate = queueRecord.callAtDate || record.Call_at_Date__c;
                const phone = queueRecord.phone || record.litify_pm__Phone__c || '';
                return {
                    Id: queueRecord.assignedTo ? (originalRecordId + '-assigned') : originalRecordId,
                    Name: record.Name || displayName || 'Unknown',
                    litify_pm__Display_Name__c: displayName,
                    Referred_By_Name__c: referredByName,
                    Status: status,
                    CaseType: caseType,
                    Qualification_Status__c: qualificationStatus,
                    callDateTime: SharedUtils.formatCallDateTime(callAtDate),
                    Phone: phone,
                    assignedTo: queueRecord.assignedTo || '',
                    assignmentTimer: this.component.timerManager.getRecordAssignmentTimer(originalRecordId, queueRecord.assignedTo, queueRecord.assignedTimestamp),
                    assignmentTimestamp: queueRecord.assignedTimestamp,
                    priorityRank: pageOffset + index + 1,
                    recordUrl: `/lightning/r/litify_pm__Intake__c/${originalRecordId}/view`,
                };
            })
            .filter(record => record);
        
        // Create working copy for display
        this.component.records = [...this.component.originalRecords];
        
        // Apply current tile filter if active
        this.applyClientSideFilter();
        
    }

    /**
     * Reset component to empty state
     */
    resetToEmptyState() {
        this.component.records = [];
        this.component.originalRecords = [];
        this.component.originalStats = SharedUtils.getDefaultStats();
        this.component.queueStats = SharedUtils.getDefaultStats();
        this.component.filterOptions = { statusOptions: [], caseTypeOptions: [] };
        this.component.tileStatusGroups = {};
        this.component.listTotalRecords = 0;
    }

    /**
     * Apply client-side filtering based on active tile filter
     */
    applyClientSideFilter() {
        // Tile filters are applied server-side to keep pagination accurate.
        this.component.records = [...this.component.originalRecords];
    }

    /**
     * Apply tile filter
     */
    async applyTileFilter() {
        this.component.currentPage = 1;
        if (typeof this.component.loadQueueData === 'function') {
            await this.component.loadQueueData();
        }
    }

    /**
     * Clear all filters
     */
    clearFilters() {
        // Increment request ID to invalidate any pending responses
        this.component.filterRequestId++;
        
        this.component.statusFilter = '';
        this.component.caseTypeFilter = '';
        this.component.dueDateFilter = '';
        this.component.currentPage = 1;
        this.component.activeTileFilter = null;
        
        // Restore original records and stats
        if (this.component.originalRecords.length > 0) {
            this.component.records = [...this.component.originalRecords];
        }
        
        this.updateTileVisualState();
        // Refresh from server to restore full dataset
        if (typeof this.component.loadQueueData === 'function') {
            this.component.loadQueueData();
        }
    }

    /**
     * Update visual state of tiles
     */
    updateTileVisualState() {
        // Update tile CSS classes for visual indication
        const tiles = this.component.template.querySelectorAll('.stat-card[data-filter]');
        tiles.forEach(tile => {
            const filterType = tile.dataset.filter;
            if (filterType === this.component.activeTileFilter) {
                tile.classList.add('active-filter');
            } else {
                tile.classList.remove('active-filter');
            }
        });
    }

    /**
     * Get table column configuration
     */
    getTableColumns() {
        return [
            {
                label: 'Priority',
                fieldName: 'priorityRank',
                type: 'number',
                cellAttributes: { alignment: 'center', class: 'nowrap-cell' },
                initialWidth: 90,
                wrapText: false
            },
            {
                label: 'Name',
                fieldName: 'recordUrl',
                type: 'url',
                typeAttributes: {
                    label: { fieldName: 'litify_pm__Display_Name__c' },
                    target: '_self'
                },
                cellAttributes: { class: 'link-cell' },
                initialWidth: 300,
                wrapText: false
            },
            {
                label: 'Referred By',
                fieldName: 'Referred_By_Name__c',
                type: 'text',
                wrapText: false
            },
            {
                label: 'Status',
                fieldName: 'Status',
                type: 'text',
                wrapText: false
            },
            {
                label: 'Case Type',
                fieldName: 'CaseType',
                type: 'text',
                wrapText: false
            },
            {
                label: 'Qualification Status',
                fieldName: 'Qualification_Status__c',
                type: 'text',
                cellAttributes: { alignment: 'left' },
                wrapText: false
            },
            {
                label: 'Call Date and Time',
                fieldName: 'callDateTime',
                type: 'text',
                sortable: true,
                wrapText: false
            },
            {
                label: 'Phone',
                fieldName: 'Phone',
                type: 'phone',
                initialWidth: 130,
                wrapText: false
            },
            {
                label: 'Currently Assigned',
                fieldName: 'assignedTo',
                type: 'text',
                wrapText: false
            },
            {
                label: 'Time Assigned',
                fieldName: 'assignmentTimer',
                type: 'text',
                cellAttributes: { alignment: 'center' },
                initialWidth: 80,
                wrapText: false
            },
            {
                type: 'action',
                typeAttributes: {
                    rowActions: this.getRowActions()
                }
            }
        ];
    }

    getRowActions() {
        return [
            { label: 'Assign to Me', name: 'assign', iconName: 'utility:user' },
            { label: 'Open Record', name: 'open', iconName: 'utility:open' }
        ];
    }
}
