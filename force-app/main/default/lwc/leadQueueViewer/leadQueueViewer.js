import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { IsConsoleNavigation } from 'lightning/platformWorkspaceApi';
import { refreshApex } from '@salesforce/apex';
import Id from '@salesforce/user/Id';
import getQueueData from '@salesforce/apex/LeadQueueService.getQueueData';
import assignRecord from '@salesforce/apex/LeadQueueService.assignRecord';
import assignNextAvailableRecord from '@salesforce/apex/LeadQueueService.assignNextAvailableRecord';
import releaseUserAssignments from '@salesforce/apex/LeadQueueService.releaseUserAssignments';
import getUserAssignedRecordIds from '@salesforce/apex/LeadQueueService.getUserAssignedRecordIds';
import getUserAssignmentData from '@salesforce/apex/LeadQueueService.getUserAssignmentData';

// Import utility modules
import { SharedUtils } from './utils/sharedUtils';
import { ConsoleNavigationManager } from './utils/consoleNavigation';
import { TimerManager } from './utils/timerManager';
import { DataProcessor } from './utils/dataProcessor';

export default class LeadQueueViewer extends NavigationMixin(LightningElement) {
    
    // Utility bar mode support
    @api utilityMode = false;
    @api label = 'Lead Queue';
    statusFilter = '';
    caseTypeFilter = '';
    dueDateFilter = '';
    activeTileFilter = null;

    // Utility managers - initialized in connectedCallback
    consoleNavigation;
    timerManager;
    dataProcessor;
    
    @track queueStats = {
        totalRecords: 0,
        highPriorityCount: 0,
        inContactCount: 0,
        noContactCount: 0,
        retainerSentCount: 0
    };
    
    // Store original stats to always show total values on tiles
    originalStats = {
        totalRecords: 0,
        highPriorityCount: 0,
        inContactCount: 0,
        noContactCount: 0,
        retainerSentCount: 0
    };
    
    @track filterOptions = {
        statusOptions: [],
        caseTypeOptions: []
    };
    
    @track hasAssignments = false;
    @track records = [];
    originalRecords = [];
    @track currentTime = new Date();
    currentUserId = Id;
    userAssignedRecordIds = [];
    userAssignmentTimestamps = {};
    isAssigning = false;
    isReleasing = false;
    @track showScheduledCalls = false;
    
    refreshInterval;
    timerInterval;
    wiredQueueResult;
    filterTimeout;
    filterRequestId = 0;
    
    // Console navigation detection
    @wire(IsConsoleNavigation) isConsoleNavigation;
    
    get dueDateOptions() {
        return SharedUtils.dueDateOptions;
    }
    
    get tableColumns() {
        return this.dataProcessor ? this.dataProcessor.getTableColumns() : [];
    }
    
    @wire(getQueueData, { 
        statusFilter: '$statusFilter', 
        caseTypeFilter: '$caseTypeFilter', 
        dueDateFilter: '$dueDateFilter',
        showScheduledCalls: '$showScheduledCalls'
    })
    wiredQueue(result) {
        this.wiredQueueResult = result;
        
        // Only process if this is the most recent request
        const currentRequestId = this.filterRequestId;
        
        if (result.data) {
            // Use requestAnimationFrame to ensure this is processed after any pending filter updates
            requestAnimationFrame(() => {
                if (this.filterRequestId === currentRequestId) {
                    this.processQueueResponse(result.data);
                }
            });
        } else if (result.error) {
            requestAnimationFrame(() => {
                if (this.filterRequestId === currentRequestId) {
                    // Clear data arrays but preserve user filter state for better UX
                    this.records = [];
                    this.originalRecords = [];
                    this.originalStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
                    this.queueStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
                    this.filterOptions = { statusOptions: [], caseTypeOptions: [] };
                    
                    // Preserve user selections: statusFilter, caseTypeFilter, dueDateFilter, activeTileFilter remain intact
                    // Only clear operational state, not user preferences
                    this.hasAssignments = false;
                    this.isAssigning = false;
                    this.isReleasing = false;
                    
                    this.showToast('Error', 'Failed to load lead queue: ' + this.getErrorMessage(result.error), 'error');
                }
            });
        }
    }
    
    // Console warm-up now handled by ConsoleNavigationManager
    
    // Workspace pre-warming now handled by ConsoleNavigationManager
    
    // Resource preloading now handled by ConsoleNavigationManager
    
    connectedCallback() {
        // Initialize utility managers
        this.consoleNavigation = new ConsoleNavigationManager(this);
        this.timerManager = new TimerManager(this);
        this.dataProcessor = new DataProcessor(this);

        // Clear any existing interval before setting new one
        if (this.refreshInterval) {
            clearInterval(this.refreshInterval);
        }
        if (this.timerInterval) {
            clearInterval(this.timerInterval);
            this.timerInterval = null;
        }
        
        // Console app warm-up optimizations
        this.consoleNavigation.warmUpConsoleApp();
        
        this.checkUserAssignments();
        this.refreshInterval = setInterval(() => {
            this.handleRefresh();
            this.checkUserAssignments();
        }, SharedUtils.CONSTANTS.REFRESH_INTERVAL);
        
        // Start live timer updates
        this.timerManager.startTimerUpdates();
    }

    renderedCallback() {
        // Intercept URL clicks for workspace navigation
        if (this.isConsoleNavigation) {
            const urlLinks = this.template.querySelectorAll('lightning-datatable a[href*="/lightning/r/litify_pm__Intake__c/"]');
            urlLinks.forEach(link => {
                if (!link.hasAttribute('data-workspace-handler')) {
                    link.setAttribute('data-workspace-handler', 'true');
                    link.addEventListener('click', (event) => {
                        event.preventDefault();
                        const href = link.getAttribute('href');
                        const recordId = href.match(/\/lightning\/r\/litify_pm__Intake__c\/([^\/]+)\//)?.[1];
                        if (recordId) {
                            this.navigateToRecord(recordId);
                        }
                    });
                }
            });
        }
    }
    
    disconnectedCallback() {
        // More robust cleanup to prevent memory leaks
        if (this.refreshInterval) {
            clearInterval(this.refreshInterval);
            this.refreshInterval = null;
        }
        
        // Stop timer updates
        if (this.timerManager) {
            this.timerManager.stopTimerUpdates();
        }
        
        if (this.filterTimeout) {
            clearTimeout(this.filterTimeout);
            this.filterTimeout = null;
        }
        
        // Enhanced cleanup to prevent memory leaks
        this.filterRequestId = 0;
        this.wiredQueueResult = null;
        this.originalRecords = [];
        this.records = [];
        this.activeTileFilter = null;
        this.originalStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
        this.queueStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
        this.filterOptions = { statusOptions: [], caseTypeOptions: [] };
        
        // Reset operational flags
        this.hasAssignments = false;
        this.isAssigning = false;
        this.isReleasing = false;

        // Clean up utility managers
        this.consoleNavigation = null;
        this.timerManager = null;
        this.dataProcessor = null;
    }
    
    processQueueResponse(data) {
        if (this.dataProcessor) {
            this.dataProcessor.processQueueResponse(data);
        }
    }
    
    // Warm up with records now handled by ConsoleNavigationManager
    
    resetToEmptyState() {
        if (this.dataProcessor) {
            this.dataProcessor.resetToEmptyState();
        }
    }
    
    applyClientSideFilter() {
        if (this.dataProcessor) {
            this.dataProcessor.applyClientSideFilter();
        }
    }
    
    
    async handleRefresh() {
        try {
            await refreshApex(this.wiredQueueResult);
        } catch (error) {
            console.error('Refresh error details:', error);
            this.showToast('Error', 'Failed to refresh data: ' + this.getErrorMessage(error), 'error');
        }
    }
    
    async handleAssignNext() {
        this.isAssigning = true;
        try {
            const result = await assignNextAvailableRecord({ showScheduledCalls: this.showScheduledCalls });
            
            if (result.success) {
                // Assignment success toast disabled per user request
                
                // Non-blocking navigation - don't wait for tab to open
                this.navigateToRecord(result.recordId);
                
                // Assignment timestamp handled by server Platform Cache
                
                // Refresh data and assignments in parallel
                Promise.all([
                    refreshApex(this.wiredQueueResult),
                    this.checkUserAssignments()
                ]).then(() => {
                    // Force re-render of utility interface
                    this.dispatchEvent(new CustomEvent('assignmentchanged'));
                }).catch(error => {
                    console.error('Error refreshing after assignment:', error);
                });
            } else {
                this.showToast('Warning', result.message, 'warning');
            }
        } catch (error) {
            this.showToast('Error', 'Assignment failed: ' + this.getErrorMessage(error), 'error');
        } finally {
            this.isAssigning = false;
        }
    }
    
    handleRowAction(event) {
        const actionName = event.detail.action.name;
        const row = event.detail.row;
        
        // Extract original record ID by removing '-assigned' suffix
        const originalRecordId = row.Id.endsWith('-assigned') 
            ? row.Id.slice(0, -9) 
            : row.Id;
        
        switch (actionName) {
            case 'assign':
                this.assignRecordToUser(originalRecordId);
                break;
        }
    }
    
    
    async assignRecordToUser(recordId) {
        this.isAssigning = true;
        try {
            const result = await assignRecord({ recordId });
            
            if (result.success) {
                // Assignment success toast disabled per user request
                
                // Non-blocking navigation - don't wait for tab to open
                this.navigateToRecord(recordId);
                
                // Assignment timestamp handled by server Platform Cache
                
                // Refresh data and assignments in parallel
                Promise.all([
                    refreshApex(this.wiredQueueResult),
                    this.checkUserAssignments()
                ]).then(() => {
                    // Force re-render of utility interface
                    this.dispatchEvent(new CustomEvent('assignmentchanged'));
                }).catch(error => {
                    console.error('Error refreshing after assignment:', error);
                });
            } else {
                this.showToast('Warning', result.message, 'warning');
            }
        } catch (error) {
            this.showToast('Error', 'Assignment failed: ' + this.getErrorMessage(error), 'error');
        } finally {
            this.isAssigning = false;
        }
    }
    
    async handleReleaseAssignments() {
        this.isReleasing = true;
        try {
            await releaseUserAssignments();
            this.showToast('Success', 'Released all assignments', 'success');
            this.hasAssignments = false;
            
            // Assignment cleanup handled by server Platform Cache
            
            await Promise.all([
                refreshApex(this.wiredQueueResult),
                this.checkUserAssignments()
            ]);
            // Force re-render of utility interface
            this.dispatchEvent(new CustomEvent('assignmentchanged'));
        } catch (error) {
            this.showToast('Error', 'Release failed: ' + this.getErrorMessage(error), 'error');
        } finally {
            this.isReleasing = false;
        }
    }
    
    async checkUserAssignments() {
        try {
            const assignmentData = await getUserAssignmentData();
            const oldHasAssignments = this.hasAssignments;
            
            // Store both record IDs and timestamps
            this.userAssignedRecordIds = Object.keys(assignmentData);
            this.userAssignmentTimestamps = assignmentData;
            this.hasAssignments = this.userAssignedRecordIds.length > 0;
            
            // If assignment status changed, force template refresh
            if (oldHasAssignments !== this.hasAssignments) {
                // Small delay to ensure DOM updates
                setTimeout(() => {
                    this.dispatchEvent(new CustomEvent('assignmentstatuschanged', {
                        detail: { hasAssignments: this.hasAssignments }
                    }));
                }, 100);
            }
        } catch (error) {
            console.error('Check assignments error details:', error);
            this.showToast('Error', 'Failed to check assignments: ' + this.getErrorMessage(error), 'error');
        }
    }
    
    handleFilterChange(event) {
        const filterName = event.target.name;
        const filterValue = event.detail.value;
        
        // Increment request ID to invalidate previous responses
        this.filterRequestId++;
        
        // Clear existing timeout and nullify reference
        if (this.filterTimeout) {
            clearTimeout(this.filterTimeout);
            this.filterTimeout = null;
        }
        
        // Set new timeout for debounced update
        this.filterTimeout = setTimeout(() => {
            if (filterName === 'status') {
                this.statusFilter = filterValue;
            } else if (filterName === 'caseType') {
                this.caseTypeFilter = filterValue;
            } else if (filterName === 'dueDate') {
                this.dueDateFilter = filterValue;
            }
            // Clear timeout reference after execution
            this.filterTimeout = null;
        }, 300);
    }
    
    async handleTileClick(event) {
        const filterType = event.currentTarget.dataset.filter;
        
        // Toggle logic: if same tile clicked, remove filter
        if (this.activeTileFilter === filterType) {
            this.activeTileFilter = null;
        } else {
            this.activeTileFilter = filterType;
        }
        
        try {
            await this.applyTileFilter();
            this.updateTileVisualState();
        } catch (error) {
            console.error('Tile filter error:', error);
            this.showToast('Error', 'Filter operation failed', 'error');
        }
    }
    
    async applyTileFilter() {
        if (this.dataProcessor) {
            await this.dataProcessor.applyTileFilter();
        }
    }
    
    
    updateTileVisualState() {
        if (this.dataProcessor) {
            this.dataProcessor.updateTileVisualState();
        }
    }

    handleClearFilters() {
        if (this.dataProcessor) {
            this.dataProcessor.clearFilters();
        }
    }
    
    handleTotalTileClick() {
        // Reset all filters to show all records
        this.handleClearFilters();
    }
    
    navigateToRecord(recordId) {
        if (this.consoleNavigation) {
            this.consoleNavigation.navigateToRecord(recordId);
        }
    }
    
    navigateToRecordNewTab(recordId) {
        this.navigateToRecord(recordId);
    }
    
    // Workspace tab opening now handled by ConsoleNavigationManager
    
    // Fallback navigation now handled by ConsoleNavigationManager
    
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title,
            message,
            variant
        }));
    }
    
    formatTime(dateTimeValue) {
        return SharedUtils.formatTime(dateTimeValue);
    }

    formatCallDateTime(dateTimeValue) {
        return SharedUtils.formatCallDateTime(dateTimeValue);
    }
    
    getErrorMessage(error) {
        return SharedUtils.getErrorMessage(error);
    }
    
    get isLoading() {
        return this.wiredQueueResult?.loading || false;
    }
    
    get hasRecords() {
        return this.records.length > 0;
    }
    
    get isAssignButtonDisabled() {
        return this.isLoading || this.isAssigning || this.isReleasing;
    }
    
    get isReleaseButtonDisabled() {
        return this.isLoading || this.isReleasing || this.isAssigning;
    }
    
    get areRowActionsDisabled() {
        return this.isLoading || this.isAssigning || this.isReleasing;
    }
    
    get assignButtonLabel() {
        return this.isAssigning ? 'Assigning...' : 'Get Next Record';
    }
    
    get releaseButtonLabel() {
        return this.isReleasing ? 'Releasing...' : 'Release My Records';
    }

    get allLeadsClass() {
        return this.activeTileFilter === null ? 'stat-card active-filter' : 'stat-card';
    }

    get readyToCallVariant() {
        return this.showScheduledCalls ? 'neutral' : 'brand';
    }

    get scheduledCallsVariant() {
        return this.showScheduledCalls ? 'brand' : 'neutral';
    }

    // Utility bar mode computed properties
    get showUtilityInterface() {
        return this.utilityMode === true;
    }

    get showFullInterface() {
        return this.utilityMode !== true;
    }

    get assignedRecordInfo() {
        return this.timerManager ? this.timerManager.getAssignedRecordInfo() : '';
    }

    get assignedRecordDisplayName() {
        return this.timerManager ? this.timerManager.getAssignedRecordDisplayName() : '';
    }

    get assignedRecordStatus() {
        return this.timerManager ? this.timerManager.getAssignedRecordStatus() : null;
    }

    get assignedRecordTimer() {
        return this.timerManager ? this.timerManager.getUtilityBarTimer() : '';
    }

    getRecordAssignmentTimer(recordId, assignedTo, assignedTimestamp) {
        return this.timerManager ? this.timerManager.getRecordAssignmentTimer(recordId, assignedTo, assignedTimestamp) : '';
    }

    refreshTableTimers() {
        if (this.timerManager) {
            this.timerManager.refreshTableTimers();
        }
    }

    // Timer functionality now managed by TimerManager utility

    showReadyToCalls() {
        if (this.showScheduledCalls) {
            this.showScheduledCalls = false;
            // Clear wire cache to force refresh
            if (this.wiredQueueResult) {
                refreshApex(this.wiredQueueResult);
            }
        }
    }

    showScheduledCallsView() {
        if (!this.showScheduledCalls) {
            this.showScheduledCalls = true;
            // Clear wire cache to force refresh
            if (this.wiredQueueResult) {
                refreshApex(this.wiredQueueResult);
            }
        }
    }
}