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
        this.component.filterOptions = data.filters || { statusOptions: [], caseTypeOptions: [] };
        this.component.tileStatusGroups = data.tileStatusGroups || {};
        
        // Validate records array
        if (!Array.isArray(data.records)) {
            console.error('Records is not an array:', data.records);
            this.component.records = [];
            return;
        }
        
        // Store original data for filter state management
        this.component.originalRecords = data.records
            .filter(queueRecord => queueRecord && queueRecord.record) // Filter out invalid entries
            .map((queueRecord, index) => {
                const record = queueRecord.record;
                const originalRecordId = record.Id;
                return {
                    Id: queueRecord.assignedTo ? (record.Id + '-assigned') : record.Id,
                    Name: record.Name || 'Unknown',
                    litify_pm__Display_Name__c: record.litify_pm__Display_Name__c || '',
                    Referred_By_Name__c: record.Referred_By_Name__c || '',
                    Status: record.litify_pm__Status__c || '',
                    CaseType: record.Case_Type_Reporting__c || '',
                    Qualification_Status__c: record.Qualification_Status__c || '',
                    callDateTime: SharedUtils.formatCallDateTime(record.Call_at_Date__c),
                    Phone: record.litify_pm__Phone__c || '',
                    assignedTo: queueRecord.assignedTo || '',
                    assignmentTimer: this.component.timerManager.getRecordAssignmentTimer(originalRecordId, queueRecord.assignedTo, queueRecord.assignedTimestamp),
                    assignmentTimestamp: queueRecord.assignedTimestamp,
                    priorityRank: index + 1,
                    recordUrl: `/lightning/r/litify_pm__Intake__c/${originalRecordId}/view`,
                };
            });
        
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
    }

    /**
     * Apply client-side filtering based on active tile filter
     */
    applyClientSideFilter() {
        if (this.component.activeTileFilter) {
            const groups = this.component.tileStatusGroups || {};
            const statuses = groups[this.component.activeTileFilter];
            if (Array.isArray(statuses) && statuses.length > 0) {
                this.component.records = this.component.originalRecords.filter(record => statuses.includes(record.Status));
                return;
            }
        }
        
        // No filter active or groups missing, show all original records
        this.component.records = [...this.component.originalRecords];
    }

    /**
     * Apply tile filter
     */
    async applyTileFilter() {
        // All tiles now use client-side filtering for consistency
        this.applyClientSideFilter();
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
