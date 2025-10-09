import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { IsConsoleNavigation } from 'lightning/platformWorkspaceApi';
// Removed refreshApex import - pure LWC approach without Aura compatibility layer
import Id from '@salesforce/user/Id';
import getQueueData from '@salesforce/apex/LeadQueueService.getQueueData';
import assignRecord from '@salesforce/apex/LeadQueueService.assignRecord';
import assignNextAvailableRecord from '@salesforce/apex/LeadQueueService.assignNextAvailableRecord';
import releaseUserAssignments from '@salesforce/apex/LeadQueueService.releaseUserAssignments';
import getUserAssignmentData from '@salesforce/apex/LeadQueueService.getUserAssignmentData';
import isCacheConfigured from '@salesforce/apex/LeadQueueService.isCacheConfigured';

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
    @track isLoadingState = false;
    @track isCacheReady = true;
    hasShownCacheWarning = false;
    
    refreshInterval;
    timerInterval;
    // Removed wiredQueueResult - pure LWC approach without Aura compatibility layer
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
    
    // Replace @wire with imperative calls to eliminate Aura compatibility layer
    async loadQueueData() {
        this.filterRequestId++;
        const currentRequestId = this.filterRequestId;
        this.isLoadingState = true;
        try {
            const result = await getQueueData({ 
                statusFilter: this.statusFilter, 
                caseTypeFilter: this.caseTypeFilter, 
                dueDateFilter: this.dueDateFilter,
                showScheduledCalls: this.showScheduledCalls
            });
            
            // Only process if this is still the most recent request
            if (this.filterRequestId === currentRequestId) {
                if (result && result.success) {
                    this.processQueueResponse(result);
                } else {
                    const message = result && result.errorMessage
                        ? result.errorMessage
                        : 'Failed to load lead queue.';
                    this.showToast('Error', message, 'error');
                }
            }
        } catch (error) {
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
                
                this.showToast('Error', 'Failed to load lead queue: ' + this.getErrorMessage(error), 'error');
            }
        } finally {
            if (this.filterRequestId === currentRequestId) {
                this.isLoadingState = false;
            }
        }
    }
    
    // Console warm-up now handled by ConsoleNavigationManager
    
    // Workspace pre-warming now handled by ConsoleNavigationManager
    
    // Resource preloading now handled by ConsoleNavigationManager
    
    async checkCacheHealth() {
        try {
            const result = await isCacheConfigured();
            this.isCacheReady = result;
            if (!result) {
                this.clearAssignmentsState(true);
                if (!this.hasShownCacheWarning) {
                    this.hasShownCacheWarning = true;
                    this.showToast('Error', 'Platform Cache not configured. Please contact your administrator.', 'error');
                }
            } else {
                this.hasShownCacheWarning = false;
            }
        } catch (error) {
            console.error('Cache health check failed:', error);
            this.isCacheReady = false;
            this.clearAssignmentsState(true);
            if (!this.hasShownCacheWarning) {
                this.hasShownCacheWarning = true;
                this.showToast('Error', 'Unable to verify Platform Cache configuration.', 'error');
            }
        }
    }
    
    clearAssignmentsState(preserveAssignmentData = false) {
        if (preserveAssignmentData) {
            this.hasAssignments = Array.isArray(this.userAssignedRecordIds) && this.userAssignedRecordIds.length > 0;
            return;
        }
        this.hasAssignments = false;
        this.userAssignedRecordIds = [];
        this.userAssignmentTimestamps = {};
    }
    
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
        this.checkCacheHealth()
            .then(() => {
                this.loadQueueData();
                if (this.isCacheReady) {
                    this.checkUserAssignments();
                }
            })
            .catch((error) => {
                console.error('Cache warm-up check error:', error);
                this.loadQueueData();
            });
        
        // Start live timer updates AFTER initial data load
        this.timerManager.startTimerUpdates();
        
        this.refreshInterval = setInterval(() => {
            this.checkCacheHealth();
            this.handleRefresh();
            if (this.isCacheReady) {
                this.checkUserAssignments();
            } else {
                this.clearAssignmentsState(true);
            }
        }, SharedUtils.CONSTANTS.REFRESH_INTERVAL);
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
        // Removed wiredQueueResult cleanup - pure LWC approach
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
        // Pure LWC refresh - no Aura compatibility layer
        await this.loadQueueData();
    }
    
    async handleAssignNext() {
        if (!this.isCacheReady) {
            this.showToast('Error', 'Platform Cache not configured. Please contact your administrator.', 'error');
            return;
        }
        this.isAssigning = true;
        try {
            const result = await assignNextAvailableRecord({
                statusFilter: this.statusFilter,
                caseTypeFilter: this.caseTypeFilter,
                dueDateFilter: this.dueDateFilter,
                showScheduledCalls: this.showScheduledCalls
            });
            
            if (result.success) {
                // Assignment success toast disabled per user request
                
                // Non-blocking navigation - don't wait for tab to open
                this.navigateToRecord(result.recordId);
                
                // Assignment timestamp handled by server Platform Cache
                
                // Refresh data and assignments in parallel (pure LWC approach)
                Promise.all([
                    this.loadQueueData(),
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
            case 'open':
                this.navigateToRecord(originalRecordId);
                break;
        }
    }
    
    
    async assignRecordToUser(recordId) {
        if (!this.isCacheReady) {
            this.showToast('Error', 'Platform Cache not configured. Please contact your administrator.', 'error');
            return;
        }
        this.isAssigning = true;
        try {
            const result = await assignRecord({ recordId });
            
            if (result.success) {
                // Assignment success toast disabled per user request
                
                // Non-blocking navigation - don't wait for tab to open
                this.navigateToRecord(recordId);
                
                // Assignment timestamp handled by server Platform Cache
                
                // Refresh data and assignments in parallel (pure LWC approach)
                Promise.all([
                    this.loadQueueData(),
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
        if (!this.isCacheReady) {
            this.showToast('Error', 'Platform Cache not configured. Please contact your administrator.', 'error');
            return;
        }
        this.isReleasing = true;
        try {
            await releaseUserAssignments();
            this.showToast('Success', 'Released all assignments', 'success');
            this.hasAssignments = false;
            
            // Assignment cleanup handled by server Platform Cache
            
            await Promise.all([
                this.loadQueueData(),
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
        if (!this.isCacheReady) {
            this.clearAssignmentsState(true);
            return;
        }
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
            // Trigger data reload after filter change (pure LWC approach)
            this.loadQueueData();
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
    
    openCacheSetup() {
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: {
                url: '/lightning/setup/PlatformCache/home'
            }
        });
    }

    handleOpenAssignedRecord() {
        const recordId = this.assignedRecordId;
        if (recordId) {
            this.navigateToRecord(recordId);
        }
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
        return this.isLoadingState;
    }
    
    get hasRecords() {
        return this.records.length > 0;
    }
    
    get isAssignButtonDisabled() {
        return this.isLoading || this.isAssigning || this.isReleasing || !this.isCacheReady;
    }
    
    get isReleaseButtonDisabled() {
        return this.isLoading || this.isReleasing || this.isAssigning || !this.isCacheReady;
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
    
    get showCacheWarning() {
        return !this.isCacheReady;
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

    get assignedRecordId() {
        if (Array.isArray(this.userAssignedRecordIds) && this.userAssignedRecordIds.length > 0) {
            return this.userAssignedRecordIds[0];
        }
        return null;
    }

    get assignedRecordStatus() {
        return this.timerManager ? this.timerManager.getAssignedRecordStatus() : null;
    }

    get assignedRecordTimer() {
        if (!this.timerManager) {
            return '';
        }
        
        try {
            return this.timerManager.getUtilityBarTimer();
        } catch (error) {
            console.log('Timer error:', error);
            return 'Time Assigned: --:--';
        }
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
            // Pure LWC approach - no Aura compatibility layer
            this.loadQueueData();
        }
    }

    showScheduledCallsView() {
        if (!this.showScheduledCalls) {
            this.showScheduledCalls = true;
            // Pure LWC approach - no Aura compatibility layer
            this.loadQueueData();
        }
    }
}
